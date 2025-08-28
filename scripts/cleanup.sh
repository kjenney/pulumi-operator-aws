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

# Configuration
NAMESPACE="${NAMESPACE:-pulumi-system}"
CLUSTER_NAME="${CLUSTER_NAME:-pulumi-aws-demo}"
STACK_NAME="${STACK_NAME:-aws-resources}"

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
    local namespaces=("pulumi-system" "pulumi-kubernetes-operator")
    
    for ns in "${namespaces[@]}"; do
        if kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${ns} &> /dev/null; then
            echo "$ns"
            return 0
        fi
    done
    
    return 1
}

find_stack_namespace() {
    local namespaces=("pulumi-system" "pulumi-kubernetes-operator")
    
    for ns in "${namespaces[@]}"; do
        if kubectl get stack ${STACK_NAME} -n ${ns} &> /dev/null; then
            echo "$ns"
            return 0
        fi
    done
    
    return 1
}

confirm_cleanup() {
    echo ""
    log_warning "This will delete:"
    echo "  - Pulumi stack and AWS resources"
    echo "  - Kubernetes secrets and configmaps"
    echo "  - Pulumi Kubernetes Operator"
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

cleanup_stack() {
    log_info "Cleaning up Pulumi stack..."
    
    # Find the stack namespace
    local stack_ns
    stack_ns=$(find_stack_namespace)
    if [[ $? -ne 0 ]]; then
        log_info "Pulumi stack not found in any namespace, skipping..."
        return 0
    fi
    
    log_info "Found stack in namespace: $stack_ns"
    
    # Delete the stack (this should trigger AWS resource cleanup)
    log_info "Deleting stack ${STACK_NAME} in namespace ${stack_ns}..."
    kubectl delete stack ${STACK_NAME} -n ${stack_ns} --timeout=600s
    
    # Wait for stack deletion to complete
    local timeout=900  # 15 minutes
    local interval=15
    local elapsed=0
    
    log_info "Waiting for AWS resources to be deleted..."
    while kubectl get stack ${STACK_NAME} -n ${stack_ns} &> /dev/null && [[ $elapsed -lt $timeout ]]; do
        log_info "Stack deletion in progress... (${elapsed}s elapsed)"
        
        # Show workspace pods if any
        local workspace_pods
        workspace_pods=$(kubectl get pods -n ${stack_ns} -l pulumi.com/stack-name=${STACK_NAME} --no-headers 2>/dev/null | wc -l)
        if [[ "$workspace_pods" -gt 0 ]]; then
            log_info "Workspace pods still running for stack cleanup..."
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    if kubectl get stack ${STACK_NAME} -n ${stack_ns} &> /dev/null; then
        log_error "Timeout waiting for stack deletion. You may need to manually delete AWS resources."
        log_info "Forcing stack deletion..."
        kubectl patch stack ${STACK_NAME} -n ${stack_ns} -p '{"metadata":{"finalizers":[]}}' --type=merge || true
        kubectl delete stack ${STACK_NAME} -n ${stack_ns} --force --grace-period=0 || true
    else
        log_success "Pulumi stack deleted successfully!"
    fi
    
    # Clean up any remaining workspace pods
    log_info "Cleaning up workspace pods..."
    kubectl delete pods -n ${stack_ns} -l pulumi.com/stack-name=${STACK_NAME} --force --grace-period=0 2>/dev/null || true
}

cleanup_kubernetes_resources() {
    log_info "Cleaning up Kubernetes resources..."
    
    # Try to clean up from multiple potential namespaces
    local namespaces=("pulumi-system" "pulumi-kubernetes-operator")
    
    for ns in "${namespaces[@]}"; do
        if kubectl get namespace ${ns} &> /dev/null; then
            log_info "Cleaning up resources in namespace: $ns"
            
            # Delete ConfigMaps
            kubectl delete configmap pulumi-program -n ${ns} --ignore-not-found=true
            
            # Delete Secrets
            kubectl delete secret aws-credentials -n ${ns} --ignore-not-found=true
            kubectl delete secret pulumi-access-token -n ${ns} --ignore-not-found=true
        fi
    done
    
    log_success "Kubernetes resources cleaned up!"
}

uninstall_operator() {
    log_info "Uninstalling Pulumi Kubernetes Operator..."
    
    # Find the operator namespace
    local operator_ns
    operator_ns=$(find_operator_namespace)
    if [[ $? -ne 0 ]]; then
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
    
    # Delete pulumi-aws-demo namespace
    kubectl delete namespace pulumi-aws-demo --ignore-not-found=true --timeout=300s
    
    # Delete operator namespaces
    local namespaces=("pulumi-system" "pulumi-kubernetes-operator")
    
    for ns in "${namespaces[@]}"; do
        if kubectl get namespace ${ns} &> /dev/null; then
            log_info "Deleting namespace: $ns"
            kubectl delete namespace ${ns} --ignore-not-found=true --timeout=300s || {
                log_warning "Force deleting namespace $ns..."
                kubectl patch namespace ${ns} -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                kubectl delete namespace ${ns} --force --grace-period=0 2>/dev/null || true
            }
        fi
    done
    
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
        buckets=$(aws s3api list-buckets --query "Buckets[?contains(Name, 'pulumi-aws-demo')].Name" --output text 2>/dev/null || echo "")
        
        if [[ -n "$buckets" ]]; then
            log_warning "Found remaining S3 buckets: $buckets"
            log_warning "You may need to manually delete these buckets from the AWS console."
            log_info "Note: S3 buckets must be empty before they can be deleted."
        else
            log_success "No matching S3 buckets found."
        fi
        
        # Check for VPCs
        local vpcs
        vpcs=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=pulumi-aws-demo" --query "Vpcs[].VpcId" --output text 2>/dev/null || echo "")
        
        if [[ -n "$vpcs" ]]; then
            log_warning "Found remaining VPCs: $vpcs"
            log_warning "You may need to manually delete these VPCs from the AWS console."
        else
            log_success "No matching VPCs found."
        fi
        
        # Check for IAM roles
        local roles
        roles=$(aws iam list-roles --query "Roles[?contains(RoleName, 'pulumi-aws-demo')].RoleName" --output text 2>/dev/null || echo "")
        
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
    echo "  ✓ Pulumi stack and AWS resources"
    echo "  ✓ Kubernetes secrets and configmaps"
    echo "  ✓ Pulumi Kubernetes Operator"
    echo "  ✓ Kubernetes namespaces"
    if [[ "${delete_cluster:-false}" == true ]]; then
        echo "  ✓ Local Kubernetes cluster"
    fi
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
    
    confirm_cleanup
    
    log_info "Starting cleanup process..."
    
    # Cleanup in reverse order of creation
    cleanup_stack
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
