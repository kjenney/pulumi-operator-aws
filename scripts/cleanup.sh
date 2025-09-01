#!/bin/bash

# cleanup.sh
# Script to clean up all resources created by the Pulumi Kubernetes Operator demo

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - support both old and new environment variable patterns
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-pulumi-system}"
STACK_NAMESPACE="${STACK_NAMESPACE:-pulumi-aws-demo}"
# Support legacy NAMESPACE variable for backwards compatibility
if [[ -n "${NAMESPACE:-}" ]]; then
    STACK_NAMESPACE="${NAMESPACE}"
fi
CLUSTER_NAME="${CLUSTER_NAME:-pulumi-aws-demo}"
STACK_NAME="${STACK_NAME:-aws-resources}"
PROJECT_NAME="${PROJECT_NAME:-aws-resources}"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

find_operator_namespace() {
    local namespaces=("${OPERATOR_NAMESPACE}" "pulumi-system" "pulumi-kubernetes-operator")
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please ensure kubectl is installed and configured."
        return 1
    fi
    
    # Check if we can connect to the cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_warning "Cannot connect to Kubernetes cluster. Skipping operator namespace detection."
        return 1
    fi
    
    for ns in "${namespaces[@]}"; do
        if kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${ns} &> /dev/null; then
            echo "$ns"
            return 0
        fi
    done
    
    return 1
}

find_stack_namespaces() {
    # Check if kubectl is available and cluster is accessible
    if ! command -v kubectl &> /dev/null; then
        return 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        return 1
    fi
    
    # Check if Stack CRD exists
    if ! kubectl get crd stacks.pulumi.com &> /dev/null; then
        return 1
    fi
    
    # Look for stacks in all namespaces and return a list
    kubectl get stacks --all-namespaces --no-headers 2>/dev/null | awk '{print $1}' | sort -u
}

load_environment() {
    # Get the directory where this script is located
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local env_file="${script_dir}/../.env"
    
    # Also check for .env in current directory
    if [[ -f ".env" ]]; then
        env_file=".env"
    fi
    
    # Load environment if .env file exists
    if [[ -f "$env_file" ]]; then
        log_info "Loading environment from: $env_file"
        set -a
        source "$env_file" 2>/dev/null || true
        set +a
        
        # Update all variables from environment with fallbacks
        OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-pulumi-system}"
        STACK_NAMESPACE="${STACK_NAMESPACE:-pulumi-aws-demo}"
        CLUSTER_NAME="${CLUSTER_NAME:-pulumi-aws-demo}"
        STACK_NAME="${STACK_NAME:-aws-resources}"
        PROJECT_NAME="${PROJECT_NAME:-aws-resources}"
        
        # Handle legacy NAMESPACE variable
        if [[ -n "${NAMESPACE:-}" ]]; then
            STACK_NAMESPACE="$NAMESPACE"
        fi
        
        log_info "Configuration loaded from .env:"
        log_info "  • Operator namespace: ${OPERATOR_NAMESPACE}"
        log_info "  • Stack namespace: ${STACK_NAMESPACE}"
        log_info "  • Cluster name: ${CLUSTER_NAME}"
        log_info "  • Project name: ${PROJECT_NAME}"
    else
        log_info "No .env file found, using default configuration"
    fi
}

confirm_cleanup() {
    echo ""
    log_warning "This will delete:"
    echo "  - Pulumi stacks and AWS resources in namespace(s): $(find_stack_namespaces | tr '\n' ' ')"
    echo "  - Kubernetes secrets and configmaps"
    echo "  - Pulumi Kubernetes Operator in namespace: ${OPERATOR_NAMESPACE}"
    echo "  - Associated Kubernetes namespaces"
    echo "  - Local Kubernetes cluster (if requested)"
    echo ""
    log_warning "AWS resources will be permanently deleted!"
    echo ""
    
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cleanup cancelled."
        exit 0
    fi
}

cleanup_stacks() {
    log_info "Cleaning up Pulumi stacks..."
    
    # Check if kubectl is available and cluster is accessible
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl not found. Skipping stack cleanup."
        return 0
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_warning "Cannot connect to Kubernetes cluster. Skipping stack cleanup."
        return 0
    fi
    
    # Check if Stack CRD exists
    if ! kubectl get crd stacks.pulumi.com &> /dev/null; then
        log_info "Stack CRD not found. No Pulumi stacks to clean up."
        return 0
    fi
    
    # Find all stack namespaces
    local stack_namespaces
    stack_namespaces=$(find_stack_namespaces)
    
    if [[ -z "$stack_namespaces" ]]; then
        log_info "No Pulumi stacks found, skipping..."
        return 0
    fi
    
    # Process each namespace that contains stacks
    while IFS= read -r stack_ns; do
        [[ -n "$stack_ns" ]] || continue
        log_info "Processing stacks in namespace: $stack_ns"
        
        # Get all stacks in this namespace first to check their status
        local stacks
        stacks=$(kubectl get stacks -n ${stack_ns} --no-headers 2>/dev/null | awk '{print $1}' || true)
        
        if [[ -n "$stacks" ]]; then
            # First, check if any stacks are currently being destroyed
            log_info "Checking stack status before cleanup..."
            while IFS= read -r stack_name; do
                [[ -n "$stack_name" ]] || continue
                local stack_status
                stack_status=$(kubectl get stack ${stack_name} -n ${stack_ns} -o jsonpath='{.status.lastUpdate.state}' 2>/dev/null || echo "unknown")
                log_info "Stack ${stack_name} status: ${stack_status}"
                
                # If stack is already being destroyed, wait for it to complete
                if [[ "$stack_status" == "destroying" ]]; then
                    log_info "Stack ${stack_name} is already being destroyed, monitoring progress..."
                    local destroy_timeout=1800  # 30 minutes for destroy operation
                    local destroy_interval=30
                    local destroy_elapsed=0
                    
                    while [[ $destroy_elapsed -lt $destroy_timeout ]]; do
                        stack_status=$(kubectl get stack ${stack_name} -n ${stack_ns} -o jsonpath='{.status.lastUpdate.state}' 2>/dev/null || echo "deleted")
                        
                        if [[ "$stack_status" == "deleted" ]] || ! kubectl get stack ${stack_name} -n ${stack_ns} &>/dev/null; then
                            log_success "Stack ${stack_name} destroyed successfully"
                            break
                        elif [[ "$stack_status" == "failed" ]]; then
                            log_error "Stack ${stack_name} destruction failed"
                            break
                        fi
                        
                        log_info "Stack ${stack_name} still destroying... (${destroy_elapsed}s elapsed, status: ${stack_status})"
                        sleep $destroy_interval
                        destroy_elapsed=$((destroy_elapsed + destroy_interval))
                    done
                fi
            done <<< "$stacks"
        fi
        
        # Now handle Helm releases after stacks are deleted
        if command -v helm &> /dev/null; then
            log_info "Checking for Helm releases in namespace ${stack_ns}..."
            local helm_releases
            helm_releases=$(helm list -n ${stack_ns} --short 2>/dev/null || true)
            
            if [[ -n "$helm_releases" ]]; then
                while IFS= read -r release_name; do
                    [[ -n "$release_name" ]] || continue
                    log_info "Uninstalling Helm release: ${release_name} in namespace ${stack_ns}..."
                    
                    # Use helm uninstall with --wait to ensure proper cleanup sequence
                    if helm uninstall "${release_name}" -n ${stack_ns} --timeout=10m --wait 2>/dev/null; then
                        log_success "Successfully uninstalled Helm release: ${release_name}"
                    else
                        log_warning "Helm uninstall encountered issues for ${release_name}, forcing cleanup..."
                        helm uninstall "${release_name}" -n ${stack_ns} --no-hooks 2>/dev/null || true
                    fi
                done <<< "$helm_releases"
            fi
        fi
        
        # Final verification - check for any remaining stacks
        local final_stacks
        final_stacks=$(kubectl get stacks -n ${stack_ns} --no-headers 2>/dev/null | wc -l)
        if [[ "$final_stacks" -eq 0 ]]; then
            log_success "All stacks cleaned up successfully in namespace ${stack_ns}"
        else
            log_warning "${final_stacks} stacks may still remain in namespace ${stack_ns}"
            log_info "Remaining stacks:"
            kubectl get stacks -n ${stack_ns} 2>/dev/null || true
        fi
        
        # Clean up any orphaned workspace pods (only after stacks are gone)
        if [[ "$final_stacks" -eq 0 ]]; then
            log_info "Cleaning up any orphaned workspace pods in ${stack_ns}..."
            local workspace_pods
            workspace_pods=$(kubectl get pods -n ${stack_ns} -l pulumi.com/stack-name --no-headers 2>/dev/null | awk '{print $1}' || true)
            if [[ -n "$workspace_pods" ]]; then
                while IFS= read -r pod_name; do
                    [[ -n "$pod_name" ]] || continue
                    log_info "Deleting orphaned workspace pod: ${pod_name}"
                    kubectl delete pod ${pod_name} -n ${stack_ns} --timeout=60s 2>/dev/null || true
                done <<< "$workspace_pods"
            fi
        fi
        
    done <<< "$stack_namespaces"
    
    log_success "Pulumi stacks cleanup completed!"
    log_info "Note: AWS resources should be cleaned up automatically by Pulumi's destroyOnFinalize."
    log_info "If any AWS resources remain, check the workspace pod logs and AWS console."
}

cleanup_kubernetes_resources() {
    log_info "Cleaning up Kubernetes resources..."
    
    # Check if kubectl is available and cluster is accessible
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl not found. Skipping Kubernetes resource cleanup."
        return 0
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_warning "Cannot connect to Kubernetes cluster. Skipping Kubernetes resource cleanup."
        return 0
    fi
    
    # Get all namespaces that might contain our resources
    local namespaces
    namespaces=$(echo -e "${STACK_NAMESPACE}\n${OPERATOR_NAMESPACE}\npulumi-system\npulumi-kubernetes-operator\n${STACK_NAMESPACE}" | sort -u)
    
    while IFS= read -r ns; do
        [[ -n "$ns" ]] || continue
        if kubectl get namespace ${ns} &> /dev/null; then
            log_info "Cleaning up resources in namespace: $ns"
            
            # Delete ConfigMaps (only if they exist)
            if kubectl get configmap pulumi-program -n ${ns} &> /dev/null; then
                kubectl delete configmap pulumi-program -n ${ns} --ignore-not-found=true
            fi
            
            # Delete Secrets (only if they exist)
            if kubectl get secret aws-credentials -n ${ns} &> /dev/null; then
                kubectl delete secret aws-credentials -n ${ns} --ignore-not-found=true
            fi
            if kubectl get secret pulumi-access-token -n ${ns} &> /dev/null; then
                kubectl delete secret pulumi-access-token -n ${ns} --ignore-not-found=true
            fi
            
            # Delete Service Accounts (only if they exist)
            if kubectl get serviceaccount pulumi -n ${ns} &> /dev/null; then
                kubectl delete serviceaccount pulumi -n ${ns} --ignore-not-found=true
            fi
        else
            log_info "Namespace $ns does not exist, skipping..."
        fi
    done <<< "$namespaces"
    
    # Delete ClusterRole and ClusterRoleBinding (only if they exist)
    log_info "Cleaning up cluster-wide RBAC resources..."
    if kubectl get clusterrole pulumi-stack-manager &> /dev/null; then
        kubectl delete clusterrole pulumi-stack-manager --ignore-not-found=true
    fi
    if kubectl get clusterrolebinding pulumi-stack-manager &> /dev/null; then
        kubectl delete clusterrolebinding pulumi-stack-manager --ignore-not-found=true
    fi
    if kubectl get clusterrolebinding pulumi:system:auth-delegator &> /dev/null; then
        kubectl delete clusterrolebinding pulumi:system:auth-delegator --ignore-not-found=true
    fi
    
    log_success "Kubernetes resources cleaned up!"
}

uninstall_operator() {
    log_info "Uninstalling Pulumi Kubernetes Operator..."
    
    # Check if kubectl is available and cluster is accessible
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl not found. Skipping operator uninstall."
        return 0
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_warning "Cannot connect to Kubernetes cluster. Skipping operator uninstall."
        return 0
    fi
    
    # Find the operator namespace
    local operator_ns
    if ! operator_ns=$(find_operator_namespace); then
        log_info "Pulumi Kubernetes Operator not found, skipping..."
        return 0
    fi
    
    log_info "Found operator in namespace: $operator_ns"
    
    # Try to uninstall using Helm first
    if command -v helm &> /dev/null; then
        log_info "Attempting Helm uninstallation..."
        helm uninstall pulumi-kubernetes-operator -n ${operator_ns} 2>/dev/null || true
    fi
    
    # Delete operator deployment if still exists
    kubectl delete deployment pulumi-kubernetes-operator-controller-manager -n ${operator_ns} --ignore-not-found=true
    
    # Delete any remaining operator resources
    kubectl delete pods -n ${operator_ns} -l app.kubernetes.io/name=pulumi-kubernetes-operator --force --grace-period=0 2>/dev/null || true
    kubectl delete pods -n ${operator_ns} -l app.kubernetes.io/component=controller --force --grace-period=0 2>/dev/null || true
    
    # Delete services, configmaps, and other operator resources
    kubectl delete service -n ${operator_ns} -l app.kubernetes.io/name=pulumi-kubernetes-operator --ignore-not-found=true
    kubectl delete configmap -n ${operator_ns} -l app.kubernetes.io/name=pulumi-kubernetes-operator --ignore-not-found=true
    kubectl delete secret -n ${operator_ns} -l app.kubernetes.io/name=pulumi-kubernetes-operator --ignore-not-found=true
    
    # Delete CRDs (only if they exist)
    log_info "Deleting Pulumi CRDs..."
    local crds=("stacks.pulumi.com" "workspaces.pulumi.com" "programs.pulumi.com" "updates.pulumi.com")
    for crd in "${crds[@]}"; do
        if kubectl get crd ${crd} &> /dev/null; then
            kubectl delete crd ${crd} --ignore-not-found=true
        fi
    done
    
    log_success "Pulumi Kubernetes Operator uninstalled!"
}

cleanup_namespaces() {
    log_info "Cleaning up namespaces..."
    
    # Check if kubectl is available and cluster is accessible
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl not found. Skipping namespace cleanup."
        return 0
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_warning "Cannot connect to Kubernetes cluster. Skipping namespace cleanup."
        return 0
    fi
    
    # List of namespaces to potentially delete
    local namespaces_to_delete=("${STACK_NAMESPACE}")
    
    # Only delete operator namespace if it's not a system namespace
    if [[ "${OPERATOR_NAMESPACE}" != "kube-system" ]] && [[ "${OPERATOR_NAMESPACE}" != "default" ]]; then
        namespaces_to_delete+=("${OPERATOR_NAMESPACE}")
    fi
    
    # Also include common operator namespaces
    namespaces_to_delete+=("pulumi-system" "pulumi-kubernetes-operator")
    
    # Remove duplicates and delete namespaces
    local unique_namespaces
    unique_namespaces=$(printf '%s\n' "${namespaces_to_delete[@]}" | sort -u)
    
    while IFS= read -r ns; do
        [[ -n "$ns" ]] || continue
        
        # Skip system namespaces
        if [[ "$ns" == "kube-system" ]] || [[ "$ns" == "default" ]] || [[ "$ns" == "kube-public" ]] || [[ "$ns" == "kube-node-lease" ]]; then
            continue
        fi
        
        if kubectl get namespace ${ns} &> /dev/null; then
            log_info "Deleting namespace: $ns"
            kubectl delete namespace ${ns} --ignore-not-found=true --timeout=300s || {
                log_warning "Force deleting namespace $ns..."
                kubectl patch namespace ${ns} -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                kubectl delete namespace ${ns} --force --grace-period=0 2>/dev/null || true
            }
        fi
    done <<< "$unique_namespaces"
    
    log_success "Namespaces cleaned up!"
}

confirm_operator_deletion() {
    echo ""
    log_info "Pulumi Stack cleanup completed successfully."
    log_warning "The Pulumi Kubernetes Operator is still running and can manage other stacks."
    echo ""
    echo "Do you want to uninstall the Pulumi Kubernetes Operator as well?"
    echo "  • Choose 'yes' if you're done with all Pulumi operations on this cluster"
    echo "  • Choose 'no' if you want to keep the operator for other stacks"
    echo ""
    read -p "Uninstall the Pulumi Kubernetes Operator? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0  # Proceed with operator uninstall
    else
        log_info "Keeping Pulumi Kubernetes Operator running..."
        log_info "You can uninstall it later by running this script again or using Helm directly."
        return 1  # Skip operator uninstall
    fi
}

cleanup_cluster() {
    local delete_cluster=false
    
    # Check if kind is available
    if ! command -v kind &> /dev/null; then
        log_info "kind not found. Skipping cluster cleanup."
        return 0
    fi
    
    # Check if the cluster exists
    if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_info "Cluster '${CLUSTER_NAME}' not found. Skipping cluster cleanup."
        return 0
    fi
    
    echo ""
    read -p "Do you want to delete the local Kubernetes cluster? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        delete_cluster=true
    fi
    
    if [[ "$delete_cluster" == true ]]; then
        log_info "Deleting local Kubernetes cluster..."
        
        if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
            kind delete cluster --name="${CLUSTER_NAME}"
            log_success "Kubernetes cluster deleted successfully!"
        else
            log_info "Cluster '${CLUSTER_NAME}' not found, skipping..."
        fi
    else
        log_info "Keeping Kubernetes cluster..."
        log_info "To delete it later, run: kind delete cluster --name ${CLUSTER_NAME}"
    fi
}

handle_stuck_stacks() {
    log_info "Checking for stuck Pulumi stacks with finalizers..."
    
    # Check if Stack CRD exists
    if ! kubectl get crd stacks.pulumi.com &> /dev/null; then
        log_info "Stack CRD not found, no stacks to handle"
        return 0
    fi
    
    # Find all stacks with finalizers that are being deleted
    local stuck_stacks
    stuck_stacks=$(kubectl get stacks --all-namespaces -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
    
    if [[ -z "$stuck_stacks" ]]; then
        log_info "No stuck stacks found"
        return 0
    fi
    
    log_warning "Found stuck stacks with deletion timestamp but still present:"
    while IFS= read -r stack_info; do
        [[ -n "$stack_info" ]] || continue
        local stack_ns=$(echo "$stack_info" | cut -d'/' -f1)
        local stack_name=$(echo "$stack_info" | cut -d'/' -f2)
        
        log_info "Checking stuck stack: ${stack_name} in namespace ${stack_ns}"
        
        # Check stack status
        local stack_status
        stack_status=$(kubectl get stack ${stack_name} -n ${stack_ns} -o jsonpath='{.status.lastUpdate.state}' 2>/dev/null || echo "unknown")
        
        # Check if stack has finalizers
        local has_finalizers
        has_finalizers=$(kubectl get stack ${stack_name} -n ${stack_ns} -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
        
        log_info "Stack ${stack_name} status: ${stack_status}, finalizers: ${has_finalizers}"
        
        # If stack is stuck in processing and credentials are missing, remove finalizers
        if [[ "$stack_status" == "failed" ]] || [[ "$stack_status" == "StackProcessing" ]]; then
            # Check if AWS credentials secret exists
            local creds_secret
            creds_secret=$(kubectl get secret aws-credentials -n ${stack_ns} 2>/dev/null || echo "missing")
            
            if [[ "$creds_secret" == "missing" ]]; then
                log_warning "Stack ${stack_name} is stuck and AWS credentials are missing"
                log_info "Removing finalizers to allow deletion (AWS resources may need manual cleanup)"
                
                # Remove finalizers to allow deletion
                if kubectl patch stack ${stack_name} -n ${stack_ns} -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null; then
                    log_success "Finalizers removed from stack ${stack_name}"
                else
                    log_error "Failed to remove finalizers from stack ${stack_name}"
                fi
            else
                log_info "AWS credentials are present, allowing stack to continue destruction process"
            fi
        fi
        
    done <<< "$stuck_stacks"
    
    # Wait a bit for finalizer removal to take effect
    if [[ -n "$stuck_stacks" ]]; then
        log_info "Waiting 30 seconds for finalizer removal to take effect..."
        sleep 30
    fi
}

cleanup_argocd_applications() {
    log_info "Cleaning up ArgoCD applications..."
    
    # Check if kubectl is available and cluster is accessible
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl not found. Skipping ArgoCD application cleanup."
        return 0
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_warning "Cannot connect to Kubernetes cluster. Skipping ArgoCD application cleanup."
        return 0
    fi
    
    # Check if ArgoCD namespace exists
    local argocd_namespace="argocd"
    if ! kubectl get namespace ${argocd_namespace} &> /dev/null; then
        log_info "ArgoCD namespace not found. Skipping ArgoCD application cleanup."
        return 0
    fi
    
    # Look for the app-of-apps first
    local app_of_apps="pulumi-operator-aws"
    if kubectl get application ${app_of_apps} -n ${argocd_namespace} &> /dev/null; then
        log_info "Found App-of-Apps: ${app_of_apps}"
        
        echo ""
        log_warning "This will delete the App-of-Apps application which will:"
        echo "  1. Trigger deletion of child applications (operator, stack)"
        echo "  2. Automatically delete Pulumi stacks and AWS resources"
        echo "  3. Clean up resources in the proper order (stack first, then operator)"
        echo ""
        read -p "Delete the App-of-Apps application? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping ArgoCD application cleanup."
            return 0
        fi
        
        # Delete the app-of-apps - this will cascade to all child applications
        log_info "Deleting App-of-Apps: ${app_of_apps}"
        kubectl delete application ${app_of_apps} -n ${argocd_namespace} --timeout=600s 2>/dev/null || {
            log_warning "Failed to delete App-of-Apps ${app_of_apps}, trying to force delete..."
            kubectl patch application ${app_of_apps} -n ${argocd_namespace} -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            kubectl delete application ${app_of_apps} -n ${argocd_namespace} --force --grace-period=0 2>/dev/null || true
        }
        
        # Wait for the app-of-apps and its children to be fully deleted
        log_info "Waiting for App-of-Apps and child applications to be deleted..."
        local delete_wait_timeout=900  # 15 minutes for full cleanup
        local delete_wait_interval=30
        local delete_wait_elapsed=0
        
        while [[ $delete_wait_elapsed -lt $delete_wait_timeout ]]; do
            # Check if any applications still exist
            local remaining_apps
            remaining_apps=$(kubectl get applications -n ${argocd_namespace} --no-headers 2>/dev/null | wc -l || echo "0")
            
            # Check for stuck Pulumi stacks that might be blocking application deletion
            if [[ "$remaining_apps" -gt 0 ]] && [[ $delete_wait_elapsed -gt 300 ]]; then  # After 5 minutes
                log_warning "Applications still exist after 5 minutes, checking for stuck Pulumi stacks..."
                handle_stuck_stacks
            fi
            
            if [[ "$remaining_apps" -eq 0 ]]; then
                log_success "All ArgoCD applications have been deleted"
                break
            fi
            
            log_info "Waiting for ${remaining_apps} applications to be deleted... (${delete_wait_elapsed}s elapsed)"
            kubectl get applications -n ${argocd_namespace} --no-headers 2>/dev/null || true
            
            sleep $delete_wait_interval
            delete_wait_elapsed=$((delete_wait_elapsed + delete_wait_interval))
        done
        
        if [[ $delete_wait_elapsed -ge $delete_wait_timeout ]]; then
            log_warning "Timeout waiting for all applications to be deleted"
            log_info "Remaining applications:"
            kubectl get applications -n ${argocd_namespace} 2>/dev/null || true
            
            # Final attempt to handle any stuck stacks
            log_warning "Attempting to resolve stuck stacks as final cleanup step..."
            handle_stuck_stacks
        fi
        
    else
        # Fallback: check for other applications and delete them individually
        local argocd_apps
        argocd_apps=$(kubectl get applications -n ${argocd_namespace} --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null || echo "")
        
        if [[ -z "$argocd_apps" ]]; then
            log_info "No ArgoCD applications found. Skipping application cleanup."
            return 0
        fi
        
        log_info "App-of-Apps not found, but found other applications:"
        kubectl get applications -n ${argocd_namespace} -o wide 2>/dev/null || true
        
        echo ""
        read -p "Delete all ArgoCD applications? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping ArgoCD application cleanup."
            return 0
        fi
        
        # Delete all applications
        while IFS= read -r app_name; do
            [[ -n "$app_name" ]] || continue
            log_info "Deleting application: ${app_name}"
            kubectl delete application ${app_name} -n ${argocd_namespace} --timeout=300s 2>/dev/null || {
                log_warning "Failed to delete application ${app_name}, continuing..."
            }
        done <<< "$argocd_apps"
    fi
    
    # Final verification
    local final_apps
    final_apps=$(kubectl get applications -n ${argocd_namespace} --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [[ "$final_apps" -eq 0 ]]; then
        log_success "All ArgoCD applications have been deleted"
    else
        log_warning "${final_apps} ArgoCD applications may still remain"
        kubectl get applications -n ${argocd_namespace} 2>/dev/null || true
    fi
}

confirm_argocd_deletion() {
    echo ""
    log_info "ArgoCD may be installed in the cluster."
    log_warning "ArgoCD can manage other applications beyond this demo."
    echo ""
    echo "Do you want to uninstall ArgoCD as well?"
    echo "  • Choose 'yes' if this is a demo cluster and you're done with ArgoCD"
    echo "  • Choose 'no' if you want to keep ArgoCD for other applications"
    echo ""
    read -p "Uninstall ArgoCD? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0  # Proceed with ArgoCD uninstall
    else
        log_info "Keeping ArgoCD running..."
        log_info "You can uninstall it later manually if needed."
        return 1  # Skip ArgoCD uninstall
    fi
}

uninstall_argocd() {
    log_info "Uninstalling ArgoCD..."
    
    # Check if kubectl is available and cluster is accessible
    if ! command -v kubectl &> /dev/null; then
        log_warning "kubectl not found. Skipping ArgoCD uninstall."
        return 0
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_warning "Cannot connect to Kubernetes cluster. Skipping ArgoCD uninstall."
        return 0
    fi
    
    # Check if ArgoCD is installed
    local argocd_namespace="argocd"
    if ! kubectl get namespace ${argocd_namespace} &> /dev/null; then
        log_info "ArgoCD namespace not found. Skipping ArgoCD uninstall."
        return 0
    fi
    
    # Check if ArgoCD applications exist and warn user
    local argocd_apps
    argocd_apps=$(kubectl get applications -n ${argocd_namespace} --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [[ "$argocd_apps" -gt 0 ]]; then
        log_warning "Found ${argocd_apps} ArgoCD applications that will be deleted:"
        kubectl get applications -n ${argocd_namespace} -o wide 2>/dev/null || true
        echo ""
        read -p "Continue with ArgoCD uninstall? This will delete all ArgoCD applications! (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping ArgoCD uninstall due to existing applications."
            return 0
        fi
    fi
    
    log_info "Removing ArgoCD applications..."
    # Delete all ArgoCD applications first
    kubectl delete applications --all -n ${argocd_namespace} --timeout=300s 2>/dev/null || true
    
    log_info "Removing ArgoCD components..."
    # Delete ArgoCD installation
    # Try to get the ArgoCD version to use the correct manifests
    local argocd_version="stable"
    
    # Delete ArgoCD using the same manifests that were used to install
    if kubectl get deployment argocd-server -n ${argocd_namespace} &> /dev/null; then
        log_info "Deleting ArgoCD manifests..."
        kubectl delete -n ${argocd_namespace} -f https://raw.githubusercontent.com/argoproj/argo-cd/${argocd_version}/manifests/install.yaml --timeout=300s 2>/dev/null || {
            log_warning "Failed to delete via manifest, trying manual cleanup..."
            
            # Manual cleanup if manifest deletion fails
            kubectl delete deployment --all -n ${argocd_namespace} --force --grace-period=0 2>/dev/null || true
            kubectl delete replicaset --all -n ${argocd_namespace} --force --grace-period=0 2>/dev/null || true
            kubectl delete pod --all -n ${argocd_namespace} --force --grace-period=0 2>/dev/null || true
            kubectl delete service --all -n ${argocd_namespace} --timeout=60s 2>/dev/null || true
            kubectl delete configmap --all -n ${argocd_namespace} --timeout=60s 2>/dev/null || true
            kubectl delete secret --all -n ${argocd_namespace} --timeout=60s 2>/dev/null || true
        }
    fi
    
    log_info "Cleaning up ArgoCD CRDs and cluster resources..."
    # Delete ArgoCD CRDs (only if they exist)
    local argocd_crds=("applications.argoproj.io" "applicationsets.argoproj.io" "appprojects.argoproj.io")
    for crd in "${argocd_crds[@]}"; do
        if kubectl get crd ${crd} &> /dev/null; then
            log_info "Deleting CRD: ${crd}"
            kubectl delete crd ${crd} --timeout=120s 2>/dev/null || true
        fi
    done
    
    # Delete ClusterRoles and ClusterRoleBindings
    log_info "Cleaning up ArgoCD RBAC resources..."
    kubectl delete clusterrole -l app.kubernetes.io/part-of=argocd --timeout=60s 2>/dev/null || true
    kubectl delete clusterrolebinding -l app.kubernetes.io/part-of=argocd --timeout=60s 2>/dev/null || true
    
    # Also try specific names in case labels don't work
    local argocd_cluster_resources=("argocd-server" "argocd-application-controller" "argocd-applicationset-controller")
    for resource in "${argocd_cluster_resources[@]}"; do
        kubectl delete clusterrole ${resource} --timeout=60s 2>/dev/null || true
        kubectl delete clusterrolebinding ${resource} --timeout=60s 2>/dev/null || true
    done
    
    # Delete namespace last
    log_info "Deleting ArgoCD namespace..."
    kubectl delete namespace ${argocd_namespace} --timeout=300s 2>/dev/null || {
        log_warning "Force deleting ArgoCD namespace..."
        kubectl patch namespace ${argocd_namespace} -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        kubectl delete namespace ${argocd_namespace} --force --grace-period=0 2>/dev/null || true
    }
    
    # Clean up credentials file
    if [[ -f "argocd-credentials.txt" ]]; then
        log_info "Removing ArgoCD credentials file..."
        rm -f argocd-credentials.txt
    fi
    
    log_success "ArgoCD uninstalled!"
}

verify_aws_cleanup() {
    log_info "Verifying AWS resource cleanup..."
    
    if command -v aws &> /dev/null; then
        log_info "Checking for remaining AWS resources..."
        
        # Check for S3 buckets
        local buckets
        buckets=$(aws s3api list-buckets --query "Buckets[?contains(Name, '${PROJECT_NAME}')].Name" --output text 2>/dev/null || echo "")
        
        if [[ -n "$buckets" ]]; then
            log_warning "Found remaining S3 buckets: $buckets"
            log_warning "You may need to manually delete these buckets from the AWS console."
            log_info "Note: S3 buckets must be empty before they can be deleted."
        else
            log_success "No matching S3 buckets found."
        fi
        
        # Check for VPCs
        local vpcs
        vpcs=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=${PROJECT_NAME}" --query "Vpcs[].VpcId" --output text 2>/dev/null || echo "")
        
        if [[ -n "$vpcs" ]]; then
            log_warning "Found remaining VPCs: $vpcs"
            log_warning "You may need to manually delete these VPCs from the AWS console."
        else
            log_success "No matching VPCs found."
        fi
        
        # Check for IAM roles
        local roles
        roles=$(aws iam list-roles --query "Roles[?contains(RoleName, '${PROJECT_NAME}')].RoleName" --output text 2>/dev/null || echo "")
        
        if [[ -n "$roles" ]]; then
            log_warning "Found remaining IAM roles: $roles"
            log_warning "You may need to manually delete these roles from the AWS console."
        else
            log_success "No matching IAM roles found."
        fi
        
        log_info "Please check your AWS console to ensure all resources have been deleted."
    else
        log_info "AWS CLI not found. Please manually verify AWS resource cleanup in the console."
    fi
}

display_cleanup_summary() {
    log_success "Cleanup completed!"
    echo ""
    log_info "What was cleaned up:"
    
    # Show ArgoCD application cleanup status
    if [[ "${argocd_apps_cleaned:-false}" == true ]]; then
        echo "  ✓ ArgoCD Applications (triggered Pulumi stack deletion)"
        echo "  ✓ Pulumi stacks and AWS resources (via ArgoCD)"
    else
        echo "  ✓ Pulumi stacks and AWS resources (manual cleanup)"
    fi
    
    echo "  ✓ Kubernetes secrets and configmaps"
    echo "  ✓ RBAC resources (ClusterRoles and ClusterRoleBindings)"
    
    # Show operator status based on what was actually done
    if [[ "${operator_uninstalled:-false}" == true ]]; then
        echo "  ✓ Pulumi Kubernetes Operator"
        echo "  ✓ Kubernetes namespaces"
    else
        echo "  • Pulumi Kubernetes Operator (kept running)"
        echo "  • Kubernetes namespaces (kept for operator)"
    fi
    
    # Show ArgoCD status based on what was actually done
    if [[ "${argocd_uninstalled:-false}" == true ]]; then
        echo "  ✓ ArgoCD and all applications"
        echo "  ✓ ArgoCD credentials file"
    else
        echo "  • ArgoCD (kept running)"
        echo "  • ArgoCD applications (kept for GitOps)"
    fi
    
    if [[ "${delete_cluster:-false}" == true ]]; then
        echo "  ✓ Local Kubernetes cluster"
    fi
    echo ""
    log_info "Namespace information:"
    echo "  • Operator namespace: ${OPERATOR_NAMESPACE}"
    echo "  • Stack namespace: ${STACK_NAMESPACE}"
    echo ""
    
    if [[ "${operator_uninstalled:-false}" != true ]]; then
        log_info "Pulumi Kubernetes Operator is still running:"
        echo "  • The operator can manage other Pulumi stacks"
        echo "  • To uninstall it later, run this script again"
        echo "  • Or use: helm uninstall pulumi-kubernetes-operator -n ${OPERATOR_NAMESPACE}"
        echo ""
    fi
    
    if [[ "${argocd_uninstalled:-false}" != true ]]; then
        # Only show ArgoCD info if it's actually installed
        if kubectl get namespace argocd &> /dev/null 2>&1; then
            log_info "ArgoCD is still running:"
            echo "  • ArgoCD can manage other applications via GitOps"
            
            # Check if there are remaining applications
            local remaining_apps
            remaining_apps=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l || echo "0")
            if [[ "$remaining_apps" -gt 0 ]]; then
                echo "  • ${remaining_apps} ArgoCD applications are still active"
                echo "  • View applications: kubectl get applications -n argocd"
            fi
            
            echo "  • To uninstall ArgoCD later, run this script again"
            echo "  • Or manually clean up applications first, then ArgoCD"
            echo ""
        fi
    fi
    
    log_warning "Important reminders:"
    echo "  • Check your AWS console to verify all resources are deleted"
    echo "  • Review your AWS bill to ensure no unexpected charges"
    echo "  • Consider setting up AWS billing alerts for future projects"
    echo ""
    log_info "Thank you for trying the Pulumi Kubernetes Operator demo!"
}

main() {
    log_info "Pulumi Kubernetes Operator AWS Demo Cleanup"
    echo "=============================================="
    
    # Load environment variables first
    load_environment
    
    confirm_cleanup
    
    log_info "Starting cleanup process..."
    
    # Cleanup in reverse order of creation
    
    # Step 1: Clean up ArgoCD applications first (which will properly delete Pulumi stacks)
    # Check if ArgoCD applications exist before asking
    local has_argocd_apps=false
    if kubectl get namespace argocd &> /dev/null 2>&1 && kubectl get applications -n argocd &> /dev/null 2>&1; then
        local app_count
        app_count=$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l || echo "0")
        if [[ "$app_count" -gt 0 ]]; then
            has_argocd_apps=true
        fi
    fi
    
    argocd_apps_cleaned=false
    if [[ "$has_argocd_apps" == true ]]; then
        echo ""
        log_info "ArgoCD applications detected. These should be cleaned up first to ensure proper Pulumi stack deletion."
        cleanup_argocd_applications
        argocd_apps_cleaned=true
        
        # After ArgoCD app cleanup, skip manual stack cleanup since ArgoCD handled it
        log_info "ArgoCD applications handled stack cleanup. Skipping manual stack cleanup."
        skip_manual_stack_cleanup=true
    else
        log_info "No ArgoCD applications found. Proceeding with manual cleanup."
        skip_manual_stack_cleanup=false
    fi
    
    # Step 2: Clean up stacks manually (only if not handled by ArgoCD)
    if [[ "${skip_manual_stack_cleanup:-false}" != true ]]; then
        cleanup_stacks
    fi
    
    # Step 3: Clean up other Kubernetes resources
    cleanup_kubernetes_resources
    
    # Step 4: Ask user if they want to uninstall the operator
    if confirm_operator_deletion; then
        uninstall_operator
        cleanup_namespaces
        operator_uninstalled=true
    else
        log_info "Skipping operator uninstall and namespace cleanup..."
        log_info "Note: Operator and stack namespaces will remain."
        operator_uninstalled=false
    fi
    
    # Step 5: Ask user if they want to uninstall ArgoCD
    if confirm_argocd_deletion; then
        uninstall_argocd
        argocd_uninstalled=true
    else
        log_info "Skipping ArgoCD uninstall..."
        log_info "Note: ArgoCD will remain."
        argocd_uninstalled=false
    fi
    
    cleanup_cluster
    verify_aws_cleanup
    display_cleanup_summary
    
    log_success "All cleanup operations completed!"
}

# Run main function
main "$@"
