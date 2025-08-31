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
        
        # Check for Helm releases and handle them properly for local backend
        if command -v helm &> /dev/null; then
            log_info "Checking for Helm releases in namespace ${stack_ns}..."
            local helm_releases
            helm_releases=$(helm list -n ${stack_ns} --short 2>/dev/null || true)
            
            if [[ -n "$helm_releases" ]]; then
                while IFS= read -r release_name; do
                    [[ -n "$release_name" ]] || continue
                    log_info "Initiating graceful uninstall of Helm release: ${release_name} in namespace ${stack_ns}..."
                    
                    # For local backend, we need to ensure AWS resources are cleaned up first
                    # Before helm uninstall, let the stack controller handle the destroy
                    log_info "Allowing Pulumi stack to complete AWS resource cleanup before Helm uninstall..."
                    
                    # Use helm uninstall with --wait to ensure proper cleanup sequence
                    if helm uninstall "${release_name}" -n ${stack_ns} --timeout=20m --wait 2>/dev/null; then
                        log_success "Successfully uninstalled Helm release: ${release_name}"
                    else
                        log_warning "Helm uninstall encountered issues for ${release_name}, checking stack status..."
                        
                        # Check if any stacks still exist and their status
                        local remaining_stacks
                        remaining_stacks=$(kubectl get stacks -n ${stack_ns} --no-headers 2>/dev/null | awk '{print $1}' || true)
                        if [[ -n "$remaining_stacks" ]]; then
                            log_info "Stacks still exist, allowing more time for AWS resource cleanup..."
                            sleep 60  # Give additional time for AWS cleanup
                            
                            # Retry helm uninstall
                            if helm uninstall "${release_name}" -n ${stack_ns} --timeout=10m --wait 2>/dev/null; then
                                log_success "Successfully uninstalled Helm release: ${release_name} on retry"
                            else
                                log_warning "Helm uninstall failed for ${release_name}, will proceed with manual cleanup..."
                            fi
                        fi
                    fi
                done <<< "$helm_releases"
            fi
        fi
        
        # Handle any remaining stacks (should be rare after proper Helm cleanup)
        stacks=$(kubectl get stacks -n ${stack_ns} --no-headers 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$stacks" ]]; then
            log_info "Found remaining stacks after Helm cleanup, handling gracefully..."
            while IFS= read -r stack_name; do
                [[ -n "$stack_name" ]] || continue
                log_info "Gracefully deleting remaining stack ${stack_name} in namespace ${stack_ns}..."
                
                # DO NOT patch finalizers - let the operator handle the destroy process
                # This ensures AWS resources are properly cleaned up with local backend
                
                # Delete the stack and let the operator handle the finalization
                kubectl delete stack ${stack_name} -n ${stack_ns} --timeout=1200s 2>/dev/null || {
                    log_warning "Stack deletion timed out for ${stack_name}, checking status..."
                    
                    # Check if stack is in destroying state
                    local stack_status
                    stack_status=$(kubectl get stack ${stack_name} -n ${stack_ns} -o jsonpath='{.status.lastUpdate.state}' 2>/dev/null || echo "not found")
                    
                    if [[ "$stack_status" == "destroying" ]]; then
                        log_info "Stack ${stack_name} is being destroyed, waiting for completion..."
                        # Wait longer for destroy to complete
                        local extended_timeout=1800  # 30 minutes
                        local check_interval=30
                        local extended_elapsed=0
                        
                        while [[ $extended_elapsed -lt $extended_timeout ]]; do
                            if ! kubectl get stack ${stack_name} -n ${stack_ns} &>/dev/null; then
                                log_success "Stack ${stack_name} successfully destroyed"
                                break
                            fi
                            
                            stack_status=$(kubectl get stack ${stack_name} -n ${stack_ns} -o jsonpath='{.status.lastUpdate.state}' 2>/dev/null || echo "not found")
                            log_info "Stack ${stack_name} destroy in progress... (${extended_elapsed}s elapsed, status: ${stack_status})"
                            
                            if [[ "$stack_status" == "failed" ]]; then
                                log_error "Stack ${stack_name} destruction failed. Check the workspace pod logs for details."
                                # Show recent logs from workspace pod if available
                                local workspace_pod
                                workspace_pod=$(kubectl get pods -n ${stack_ns} -l "pulumi.com/stack-name=${stack_name}" --no-headers 2>/dev/null | awk '{print $1}' | head -1)
                                if [[ -n "$workspace_pod" ]]; then
                                    log_info "Recent logs from workspace pod ${workspace_pod}:"
                                    kubectl logs ${workspace_pod} -n ${stack_ns} --tail=20 2>/dev/null || true
                                fi
                                break
                            fi
                            
                            sleep $check_interval
                            extended_elapsed=$((extended_elapsed + check_interval))
                        done
                        
                        # If still exists after extended timeout, log error but continue
                        if kubectl get stack ${stack_name} -n ${stack_ns} &>/dev/null; then
                            log_error "Stack ${stack_name} cleanup timed out. AWS resources may still exist."
                            log_error "Check AWS console and consider manual cleanup."
                        fi
                    else
                        log_warning "Stack ${stack_name} status: ${stack_status}"
                    fi
                }
            done <<< "$stacks"
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
    echo "  ✓ Pulumi stacks and AWS resources"
    echo "  ✓ Kubernetes secrets and configmaps"
    echo "  ✓ RBAC resources (ClusterRoles and ClusterRoleBindings)"
    echo "  ✓ Pulumi Kubernetes Operator"
    echo "  ✓ Kubernetes namespaces"
    if [[ "${delete_cluster:-false}" == true ]]; then
        echo "  ✓ Local Kubernetes cluster"
    fi
    echo ""
    log_info "Namespace information:"
    echo "  • Operator was in: ${OPERATOR_NAMESPACE}"
    echo "  • Stacks were in: ${STACK_NAMESPACE}"
    echo ""
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
    cleanup_stacks
    cleanup_kubernetes_resources
    uninstall_operator
    cleanup_namespaces
    cleanup_cluster
    verify_aws_cleanup
    display_cleanup_summary
    
    log_success "All cleanup operations completed!"
}

# Run main function
main "$@"
