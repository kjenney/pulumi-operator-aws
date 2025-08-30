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
    
    for ns in "${namespaces[@]}"; do
        if kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${ns} &> /dev/null; then
            echo "$ns"
            return 0
        fi
    done
    
    return 1
}

find_stack_namespaces() {
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
        
        # Get all stacks in this namespace
        local stacks
        stacks=$(kubectl get stacks -n ${stack_ns} --no-headers 2>/dev/null | awk '{print $1}' || true)
        
        if [[ -n "$stacks" ]]; then
            while IFS= read -r stack_name; do
                [[ -n "$stack_name" ]] || continue
                log_info "Deleting stack ${stack_name} in namespace ${stack_ns}..."
                kubectl delete stack ${stack_name} -n ${stack_ns} --timeout=600s || {
                    log_warning "Failed to delete stack gracefully, forcing deletion..."
                    kubectl patch stack ${stack_name} -n ${stack_ns} -p '{"metadata":{"finalizers":[]}}' --type=merge || true
                    kubectl delete stack ${stack_name} -n ${stack_ns} --force --grace-period=0 || true
                }
            done <<< "$stacks"
            
            # Wait for stack deletions to complete
            local timeout=900  # 15 minutes
            local interval=15
            local elapsed=0
            
            log_info "Waiting for AWS resources to be deleted in namespace ${stack_ns}..."
            while [[ $elapsed -lt $timeout ]]; do
                local remaining_stacks
                remaining_stacks=$(kubectl get stacks -n ${stack_ns} --no-headers 2>/dev/null | wc -l)
                
                if [[ "$remaining_stacks" -eq 0 ]]; then
                    break
                fi
                
                log_info "Stack deletion in progress in ${stack_ns}... (${elapsed}s elapsed)"
                
                # Show workspace pods if any
                local workspace_pods
                workspace_pods=$(kubectl get pods -n ${stack_ns} -l pulumi.com/stack-name --no-headers 2>/dev/null | wc -l)
                if [[ "$workspace_pods" -gt 0 ]]; then
                    log_info "Workspace pods still running for stack cleanup..."
                fi
                
                sleep $interval
                elapsed=$((elapsed + interval))
            done
            
            # Force cleanup any remaining stacks
            local remaining_stacks
            remaining_stacks=$(kubectl get stacks -n ${stack_ns} --no-headers 2>/dev/null | awk '{print $1}' || true)
            if [[ -n "$remaining_stacks" ]]; then
                log_warning "Timeout reached, forcing deletion of remaining stacks in ${stack_ns}..."
                while IFS= read -r stack_name; do
                    [[ -n "$stack_name" ]] || continue
                    kubectl patch stack ${stack_name} -n ${stack_ns} -p '{"metadata":{"finalizers":[]}}' --type=merge || true
                    kubectl delete stack ${stack_name} -n ${stack_ns} --force --grace-period=0 || true
                done <<< "$remaining_stacks"
            fi
            
            # Clean up any remaining workspace pods
            log_info "Cleaning up workspace pods in ${stack_ns}..."
            kubectl delete pods -n ${stack_ns} -l pulumi.com/stack-name --force --grace-period=0 2>/dev/null || true
        fi
    done <<< "$stack_namespaces"
    
    log_success "Pulumi stacks cleanup completed!"
}

cleanup_kubernetes_resources() {
    log_info "Cleaning up Kubernetes resources..."
    
    # Get all namespaces that might contain our resources
    local namespaces
    namespaces=$(echo -e "${STACK_NAMESPACE}\n${OPERATOR_NAMESPACE}\npulumi-system\npulumi-kubernetes-operator\n${STACK_NAMESPACE}" | sort -u)
    
    while IFS= read -r ns; do
        [[ -n "$ns" ]] || continue
        if kubectl get namespace ${ns} &> /dev/null; then
            log_info "Cleaning up resources in namespace: $ns"
            
            # Delete ConfigMaps
            kubectl delete configmap pulumi-program -n ${ns} --ignore-not-found=true
            
            # Delete Secrets
            kubectl delete secret aws-credentials -n ${ns} --ignore-not-found=true
            kubectl delete secret pulumi-access-token -n ${ns} --ignore-not-found=true
            
            # Delete Service Accounts
            kubectl delete serviceaccount pulumi -n ${ns} --ignore-not-found=true
        fi
    done <<< "$namespaces"
    
    # Delete ClusterRole and ClusterRoleBinding
    log_info "Cleaning up cluster-wide RBAC resources..."
    kubectl delete clusterrole pulumi-stack-manager --ignore-not-found=true
    kubectl delete clusterrolebinding pulumi-stack-manager --ignore-not-found=true
    kubectl delete clusterrolebinding pulumi:system:auth-delegator --ignore-not-found=true
    
    log_success "Kubernetes resources cleaned up!"
}

uninstall_operator() {
    log_info "Uninstalling Pulumi Kubernetes Operator..."
    
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
    
    # Delete CRDs
    log_info "Deleting Pulumi CRDs..."
    kubectl delete crd stacks.pulumi.com --ignore-not-found=true
    kubectl delete crd workspaces.pulumi.com --ignore-not-found=true
    kubectl delete crd programs.pulumi.com --ignore-not-found=true
    kubectl delete crd updates.pulumi.com --ignore-not-found=true
    
    log_success "Pulumi Kubernetes Operator uninstalled!"
}

cleanup_namespaces() {
    log_info "Cleaning up namespaces..."
    
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
    
    echo ""
    read -p "Do you want to delete the local Kubernetes cluster? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        delete_cluster=true
    fi
    
    if [[ "$delete_cluster" == true ]]; then
        log_info "Deleting local Kubernetes cluster..."
        
        if command -v kind &> /dev/null; then
            if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
                kind delete cluster --name="${CLUSTER_NAME}"
                log_success "Kubernetes cluster deleted successfully!"
            else
                log_info "Cluster '${CLUSTER_NAME}' not found, skipping..."
            fi
        else
            log_warning "kind not found. Please manually delete your cluster if needed."
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
