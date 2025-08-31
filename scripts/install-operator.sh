#!/bin/bash

# install-operator.sh
# Script to install the Pulumi Kubernetes Operator

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
OPERATOR_VERSION="${OPERATOR_VERSION:-2.2.0}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-pulumi-system}"
CLUSTER_NAME="${CLUSTER_NAME:-pulumi-aws-demo}"

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

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    
    # Check helm
    if ! command -v helm &> /dev/null; then
        log_error "helm is not installed. Please install helm first."
        exit 1
    fi
    
    # Check if cluster is accessible
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot access Kubernetes cluster. Please ensure cluster is running and kubectl is configured."
        exit 1
    fi
    
    # Check Helm version (need 3.8+ for OCI support)
    local helm_version
    helm_version=$(helm version --short | grep -oE 'v[0-9]+\.[0-9]+' | head -1)
    
    # Convert version to numbers for proper comparison
    local helm_major helm_minor
    helm_major=$(echo "$helm_version" | cut -d'.' -f1 | sed 's/v//')
    helm_minor=$(echo "$helm_version" | cut -d'.' -f2)
    
    # Check if version is 3.8 or higher
    if [[ $helm_major -lt 3 ]] || [[ $helm_major -eq 3 && $helm_minor -lt 8 ]]; then
        log_error "Helm version $helm_version is too old. Need Helm 3.8+ for OCI registry support."
        log_info "Current version: $helm_version, Required: v3.8+"
        exit 1
    fi
    
    log_info "Helm version $helm_version is compatible (3.8+ required)"
    
    log_success "Prerequisites check passed!"
}

create_namespace() {
    log_info "Creating operator namespace '${OPERATOR_NAMESPACE}'..."
    
    # Create namespace if it doesn't exist
    kubectl create namespace ${OPERATOR_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "Namespace '${OPERATOR_NAMESPACE}' ready!"
}

install_operator_via_helm() {
    log_info "Installing Pulumi Kubernetes Operator ${OPERATOR_VERSION} via Helm OCI..."
    
    # Install the operator using Helm with OCI registry
    helm install pulumi-kubernetes-operator \
        oci://ghcr.io/pulumi/helm-charts/pulumi-kubernetes-operator \
        --version ${OPERATOR_VERSION} \
        --namespace ${OPERATOR_NAMESPACE} \
        --create-namespace \
        --set operator.gracefulShutdownTimeoutDuration=5m \
        --set operator.maxConcurrentReconciles=10 \
        --set operator.leaderElection.enabled=true \
        --wait --timeout=300s
    
    if [[ $? -eq 0 ]]; then
        log_success "Pulumi Kubernetes Operator installed successfully via Helm!"
        return 0
    else
        log_error "Helm installation failed. Trying alternative method..."
        return 1
    fi
}

install_operator_via_manifest() {
    log_info "Installing Pulumi Kubernetes Operator ${OPERATOR_VERSION} via manifest..."
    
    # Use the quickstart installation manifest
    kubectl apply -f https://raw.githubusercontent.com/pulumi/pulumi-kubernetes-operator/refs/tags/v${OPERATOR_VERSION}/deploy/quickstart/install.yaml
    
    log_success "Pulumi Kubernetes Operator installed successfully via manifest!"
}

verify_installation() {
    log_info "Verifying Pulumi Operator installation..."
    
    # Wait for the operator to be ready
    local timeout=300
    local interval=10
    local elapsed=0
    
    log_info "Waiting for operator deployment to be available..."
    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE} &> /dev/null; then
            if kubectl wait --for=condition=available --timeout=60s deployment/pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE} &> /dev/null; then
                break
            fi
        fi
        
        log_info "Waiting for operator... (${elapsed}s elapsed)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    # Check if the operator is running
    local operator_status
    operator_status=$(kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    
    if [[ "$operator_status" -ge "1" ]]; then
        log_success "Pulumi Operator is running successfully!"
    else
        log_error "Pulumi Operator is not ready. Status: $operator_status"
        log_info "Checking for operator in ${OPERATOR_NAMESPACE} namespace..."
        
        # Sometimes the operator might be in the operator namespace
        if kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE} &> /dev/null; then
            log_info "Found operator in ${OPERATOR_NAMESPACE} namespace"
            operator_status=$(kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            if [[ "$operator_status" -ge "1" ]]; then
                log_success "Pulumi Operator is running in ${OPERATOR_NAMESPACE} namespace!"
                return 0
            fi
        fi
        
        log_error "Operator verification failed. Checking logs..."
        kubectl describe deployment pulumi-kubernetes-operator -n ${OPERATOR_NAMESPACE} || true
        return 1
    fi
}

display_operator_info() {
    log_info "Operator Information:"
    echo "======================"

    kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE}
    echo ""
    kubectl get pods -n ${OPERATOR_NAMESPACE} -l app.kubernetes.io/name=pulumi-kubernetes-operator
    echo ""
    
    log_info "Operator logs (last 10 lines):"
    kubectl logs -n ${OPERATOR_NAMESPACE} deployment/pulumi-kubernetes-operator-controller-manager --tail=10 || true
    echo ""
    
    # Show CRDs
    log_info "Custom Resource Definitions:"
    kubectl get crd | grep pulumi || log_warning "No Pulumi CRDs found"
}

check_operator_health() {
    log_info "Checking operator health..."
    
    # Get the operator pod name
    local pod_name
    pod_name=$(kubectl get pods -n ${OPERATOR_NAMESPACE} -l app.kubernetes.io/name=pulumi-kubernetes-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$pod_name" ]]; then
        # Try alternative label selector
        pod_name=$(kubectl get pods -n ${OPERATOR_NAMESPACE} -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    if [[ -z "$pod_name" ]]; then
        log_error "Could not find operator pod"
        kubectl get pods -n ${OPERATOR_NAMESPACE}
        return 1
    fi
    
    # Check if the pod is ready
    local pod_ready
    pod_ready=$(kubectl get pod "$pod_name" -n ${OPERATOR_NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

    if [[ "$pod_ready" == "True" ]]; then
        log_success "Operator pod is healthy and ready!"
    else
        log_warning "Operator pod status: $pod_ready"
        kubectl describe pod "$pod_name" -n ${OPERATOR_NAMESPACE}
    fi
}

display_next_steps() {
    log_info "Installation completed successfully!"
    echo ""
    log_info "Next steps:"
    echo "1. Configure your AWS credentials and Pulumi access token:"
    echo "   cp .env.example .env"
    echo "   # Edit .env with your actual credentials"
    echo ""
    echo "2. Update the deployment script namespace if needed:"
    if [[ "${OPERATOR_NAMESPACE}" != "pulumi-kubernetes-operator" ]]; then
        echo "   export NAMESPACE=${OPERATOR_NAMESPACE}"
    fi
    echo ""
    echo "3. Deploy AWS resources using the operator:"
    echo "   ./scripts/deploy-stack.sh"
    echo ""
    log_info "Useful commands:"
    echo "- Check operator status: kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE}"
    echo "- View operator logs: kubectl logs -f deployment/pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE}"
    echo "- List Pulumi stacks: kubectl get stacks -A"
    echo "- Check CRDs: kubectl get crd | grep pulumi"
}

main() {
    log_info "Installing Pulumi Kubernetes Operator..."
    echo "========================================"
    
    check_prerequisites
    create_namespace
    
    # Try Helm installation first, fall back to manifest if it fails
    if ! install_operator_via_helm; then
        log_warning "Helm installation failed, trying manifest installation..."
        install_operator_via_manifest
    fi
    
    verify_installation
    display_operator_info
    check_operator_health
    display_next_steps
    
    log_success "Pulumi Kubernetes Operator installation completed!"
}

# Run main function
main "$@"
