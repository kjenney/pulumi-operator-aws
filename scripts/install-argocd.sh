#!/bin/bash

# install-argocd.sh
# Script to install ArgoCD in the Kubernetes cluster

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"

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
        
        # Update variables from environment with fallbacks
        ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
        ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
        
        log_info "Configuration loaded:"
        log_info "  • ArgoCD namespace: ${ARGOCD_NAMESPACE}"
        log_info "  • ArgoCD version: ${ARGOCD_VERSION}"
    else
        log_info "No .env file found, using default configuration"
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl and try again."
        exit 1
    fi
    
    # Check if we can connect to the cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

install_argocd() {
    log_info "Installing ArgoCD..."
    
    # Create namespace if it doesn't exist
    if ! kubectl get namespace ${ARGOCD_NAMESPACE} &> /dev/null; then
        log_info "Creating ArgoCD namespace: ${ARGOCD_NAMESPACE}"
        kubectl create namespace ${ARGOCD_NAMESPACE}
    else
        log_info "ArgoCD namespace already exists: ${ARGOCD_NAMESPACE}"
    fi
    
    # Install ArgoCD
    log_info "Applying ArgoCD manifests..."
    if [[ "$ARGOCD_VERSION" == "stable" ]]; then
        kubectl apply -n ${ARGOCD_NAMESPACE} -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    else
        kubectl apply -n ${ARGOCD_NAMESPACE} -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml
    fi
    
    log_success "ArgoCD manifests applied"
}

wait_for_argocd() {
    log_info "Waiting for ArgoCD to be ready..."
    
    # Wait for ArgoCD server deployment to be ready
    log_info "Waiting for argocd-server deployment..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n ${ARGOCD_NAMESPACE}
    
    # Wait for ArgoCD controller deployment to be ready
    log_info "Waiting for argocd-application-controller deployment..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-applicationset-controller -n ${ARGOCD_NAMESPACE}
    
    # Wait for ArgoCD repo server deployment to be ready
    log_info "Waiting for argocd-repo-server deployment..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n ${ARGOCD_NAMESPACE}
    
    log_success "ArgoCD is ready!"
}

setup_argocd_access() {
    log_info "Setting up ArgoCD access..."
    
    # Get the initial admin password
    log_info "Retrieving ArgoCD admin password..."
    local admin_password
    admin_password=$(kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    
    # Check if we're running on Kind
    local cluster_info
    cluster_info=$(kubectl cluster-info 2>/dev/null || echo "")
    
    if [[ "$cluster_info" =~ "kind" ]] || command -v kind &> /dev/null && kind get clusters 2>/dev/null | grep -q .; then
        log_info "Kind cluster detected - setting up port-forward access..."
        
        log_success "ArgoCD access configured!"
        echo ""
        log_info "ArgoCD Access Information (Kind cluster):"
        echo "  • Username: admin"
        echo "  • Password: ${admin_password}"
        echo ""
        log_info "To access ArgoCD UI, run this command in a separate terminal:"
        echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
        echo ""
        log_info "Then open your browser to:"
        echo "  https://localhost:8080"
        echo ""
        log_warning "Note: You may need to accept the self-signed certificate in your browser"
        
    else
        log_info "Non-Kind cluster detected - setting up NodePort access..."
        
        # Patch ArgoCD server service to use NodePort for direct access
        kubectl patch svc argocd-server -n ${ARGOCD_NAMESPACE} -p '{"spec":{"type":"NodePort"}}'
        
        # Get the NodePort
        local node_port
        node_port=$(kubectl get svc argocd-server -n ${ARGOCD_NAMESPACE} -o jsonpath='{.spec.ports[0].nodePort}')
        
        log_success "ArgoCD access configured!"
        echo ""
        log_info "ArgoCD Access Information:"
        echo "  • URL: http://localhost:${node_port}"
        echo "  • Username: admin"
        echo "  • Password: ${admin_password}"
    fi
    
    echo ""
    log_warning "Please save the password above - you'll need it to access ArgoCD!"
    
    # Save credentials to file
    echo "admin" > argocd-credentials.txt
    echo "${admin_password}" >> argocd-credentials.txt
    log_info "Credentials also saved to: argocd-credentials.txt"
}

check_existing_installation() {
    if kubectl get namespace ${ARGOCD_NAMESPACE} &> /dev/null; then
        if kubectl get deployment argocd-server -n ${ARGOCD_NAMESPACE} &> /dev/null; then
            log_warning "ArgoCD appears to already be installed in namespace: ${ARGOCD_NAMESPACE}"
            echo ""
            read -p "Do you want to reinstall ArgoCD? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Skipping ArgoCD installation"
                return 1
            else
                log_warning "Proceeding with reinstallation..."
                return 0
            fi
        fi
    fi
    return 0
}

main() {
    echo -e "${GREEN}ArgoCD Installation Script${NC}"
    echo "=========================="
    echo ""
    
    # Load environment variables
    load_environment
    
    # Check prerequisites
    check_prerequisites
    
    # Check for existing installation
    if ! check_existing_installation; then
        log_info "ArgoCD installation skipped by user choice"
        exit 0
    fi
    
    # Install ArgoCD
    install_argocd
    
    # Wait for ArgoCD to be ready
    wait_for_argocd
    
    # Setup access
    setup_argocd_access
    
    echo ""
    log_success "🎉 ArgoCD installation completed successfully!"
    echo ""
    log_info "Next steps:"
    echo "  1. Access ArgoCD UI at the URL shown above"
    echo "  2. Login with the admin credentials"
    echo "  3. Create ArgoCD Applications for your Helm charts"
    echo "  4. Configure Git repositories in ArgoCD settings"
    echo ""
    # Check if we're on Kind for final instructions
    local cluster_info
    cluster_info=$(kubectl cluster-info 2>/dev/null || echo "")
    
    if [[ "$cluster_info" =~ "kind" ]] || command -v kind &> /dev/null && kind get clusters 2>/dev/null | grep -q .; then
        log_info "For Kind clusters, remember to use port-forward:"
        echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
        echo "  Then access: https://localhost:8080"
    else
        log_info "For non-Kind clusters, you can also use port-forward:"
        echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
        echo "  Then access: https://localhost:8080"
    fi
}

# Handle script interruption
trap 'echo; log_error "Script interrupted!"; exit 1' INT TERM

# Run main function
main "$@"