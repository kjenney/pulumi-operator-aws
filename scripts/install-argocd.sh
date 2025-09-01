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

deploy_app_of_apps() {
    log_info "Deploying Pulumi Operator AWS App of Apps..."
    
    # Get the directory where this script is located
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local app_of_apps_file="${script_dir}/../argocd/app-of-apps.yaml"
    
    # Check if the app of apps file exists
    if [[ ! -f "$app_of_apps_file" ]]; then
        log_error "App of Apps file not found: $app_of_apps_file"
        log_error "Please ensure the argocd directory exists with app-of-apps.yaml"
        return 1
    fi
    
    # Check if AWS credentials secret exists
    log_info "Checking for AWS credentials..."
    if ! kubectl get secret aws-credentials -n pulumi-aws-demo &> /dev/null; then
        log_warning "AWS credentials secret not found in pulumi-aws-demo namespace"
        log_info "Creating placeholder namespace and secret..."
        
        # Create namespace if it doesn't exist
        kubectl create namespace pulumi-aws-demo --dry-run=client -o yaml | kubectl apply -f -
        
        # Check if AWS credentials are in environment
        if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
            log_info "Creating AWS credentials secret from environment variables..."
            kubectl create secret generic aws-credentials \
                --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
                --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
                --from-literal=AWS_REGION="${AWS_REGION:-us-west-2}" \
                -n pulumi-aws-demo
        else
            log_warning "AWS credentials not found in environment variables"
            log_warning "Creating placeholder secret - you'll need to update it with real credentials"
            kubectl create secret generic aws-credentials \
                --from-literal=AWS_ACCESS_KEY_ID="your-access-key-here" \
                --from-literal=AWS_SECRET_ACCESS_KEY="your-secret-key-here" \
                --from-literal=AWS_REGION="us-west-2" \
                -n pulumi-aws-demo
        fi
    fi
    
    # Apply the App of Apps
    log_info "Applying App of Apps configuration..."
    if kubectl apply -f "$app_of_apps_file"; then
        log_success "App of Apps deployed successfully!"
        
        # Wait a moment for ArgoCD to process the application
        sleep 5
        
        # Show the applications
        log_info "ArgoCD Applications created:"
        kubectl get applications -n argocd -o wide 2>/dev/null || true
        
        echo ""
        log_info "Monitor deployment progress:"
        echo "  • ArgoCD UI: Check the applications dashboard"
        echo "  • CLI: kubectl get applications -n argocd"
        echo "  • Watch: kubectl get applications -n argocd -w"
        echo ""
        log_warning "Note: The stack deployment will create AWS resources that may incur charges!"
        
    else
        log_error "Failed to deploy App of Apps"
        return 1
    fi
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
    local skip_installation=false
    if ! check_existing_installation; then
        skip_installation=true
        log_info "ArgoCD installation skipped by user choice"
        
        # Ask if they want to deploy app of apps anyway
        echo ""
        read -p "Do you want to deploy the Pulumi Operator AWS suite via ArgoCD App of Apps? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            deploy_app_of_apps
        fi
        exit 0
    fi
    
    # Install ArgoCD
    install_argocd
    
    # Wait for ArgoCD to be ready
    wait_for_argocd
    
    # Setup access
    setup_argocd_access
    
    echo ""
    # Ask if user wants to deploy the app of apps
    echo ""
    read -p "Do you want to deploy the Pulumi Operator AWS suite via ArgoCD App of Apps? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log_info "Skipping App of Apps deployment"
    else
        deploy_app_of_apps
    fi
    
    log_success "🎉 ArgoCD installation completed successfully!"
    echo ""
    log_info "Next steps:"
    echo "  1. Access ArgoCD UI at the URL shown above"
    echo "  2. Login with the admin credentials"
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "  3. Monitor the App of Apps deployment in ArgoCD UI"
        echo "  4. Check application status: kubectl get applications -n argocd"
    else
        echo "  3. Deploy manually: kubectl apply -f argocd/app-of-apps.yaml"
        echo "  4. Or create ArgoCD Applications via the UI"
    fi
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