#!/bin/bash

# deploy-app-of-apps.sh
# Script to deploy the Pulumi Operator AWS App of Apps to an existing ArgoCD installation

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
STACK_NAMESPACE="${STACK_NAMESPACE:-pulumi-aws-demo}"

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
        STACK_NAMESPACE="${STACK_NAMESPACE:-pulumi-aws-demo}"
        
        log_info "Configuration loaded:"
        log_info "  • ArgoCD namespace: ${ARGOCD_NAMESPACE}"
        log_info "  • Stack namespace: ${STACK_NAMESPACE}"
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
    
    # Check if ArgoCD is installed
    if ! kubectl get namespace ${ARGOCD_NAMESPACE} &> /dev/null; then
        log_error "ArgoCD namespace '${ARGOCD_NAMESPACE}' not found."
        log_error "Please install ArgoCD first: ./scripts/install-argocd.sh"
        exit 1
    fi
    
    if ! kubectl get deployment argocd-server -n ${ARGOCD_NAMESPACE} &> /dev/null; then
        log_error "ArgoCD server deployment not found in namespace '${ARGOCD_NAMESPACE}'."
        log_error "Please install ArgoCD first: ./scripts/install-argocd.sh"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

setup_aws_credentials() {
    log_info "Setting up AWS credentials..."
    
    # Create namespace if it doesn't exist
    if ! kubectl get namespace ${STACK_NAMESPACE} &> /dev/null; then
        log_info "Creating namespace: ${STACK_NAMESPACE}"
        kubectl create namespace ${STACK_NAMESPACE}
    fi
    
    # Check if AWS credentials secret already exists
    if kubectl get secret aws-credentials -n ${STACK_NAMESPACE} &> /dev/null; then
        log_info "AWS credentials secret already exists in namespace ${STACK_NAMESPACE}"
        return 0
    fi
    
    log_info "AWS credentials secret not found, creating..."
    
    # Check if AWS credentials are in environment
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        log_info "Creating AWS credentials secret from environment variables..."
        kubectl create secret generic aws-credentials \
            --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
            --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
            --from-literal=AWS_REGION="${AWS_REGION:-us-west-2}" \
            -n ${STACK_NAMESPACE}
        log_success "AWS credentials secret created from environment"
    else
        log_warning "AWS credentials not found in environment variables"
        echo ""
        log_info "Please provide your AWS credentials:"
        
        # Prompt for AWS credentials
        read -p "AWS Access Key ID: " aws_access_key_id
        read -s -p "AWS Secret Access Key: " aws_secret_access_key
        echo
        read -p "AWS Region [us-west-2]: " aws_region
        aws_region=${aws_region:-us-west-2}
        
        if [[ -z "$aws_access_key_id" ]] || [[ -z "$aws_secret_access_key" ]]; then
            log_error "AWS credentials cannot be empty"
            exit 1
        fi
        
        # Create the secret
        kubectl create secret generic aws-credentials \
            --from-literal=AWS_ACCESS_KEY_ID="$aws_access_key_id" \
            --from-literal=AWS_SECRET_ACCESS_KEY="$aws_secret_access_key" \
            --from-literal=AWS_REGION="$aws_region" \
            -n ${STACK_NAMESPACE}
        log_success "AWS credentials secret created"
    fi
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
        exit 1
    fi
    
    # Apply the App of Apps
    log_info "Applying App of Apps configuration..."
    if kubectl apply -f "$app_of_apps_file"; then
        log_success "App of Apps deployed successfully!"
        
        # Wait a moment for ArgoCD to process the application
        sleep 5
        
        # Show the applications
        log_info "ArgoCD Applications created:"
        kubectl get applications -n ${ARGOCD_NAMESPACE} -o wide 2>/dev/null || true
        
    else
        log_error "Failed to deploy App of Apps"
        exit 1
    fi
}

monitor_deployment() {
    echo ""
    log_info "Monitoring deployment progress..."
    echo ""
    
    # Show initial status
    kubectl get applications -n ${ARGOCD_NAMESPACE} -o wide 2>/dev/null || true
    
    echo ""
    log_info "Deployment monitoring commands:"
    echo "  • Watch applications: kubectl get applications -n ${ARGOCD_NAMESPACE} -w"
    echo "  • Check specific app: kubectl describe application <app-name> -n ${ARGOCD_NAMESPACE}"
    echo "  • View ArgoCD UI for detailed status and logs"
    echo ""
    
    # Check ArgoCD access info
    local cluster_info
    cluster_info=$(kubectl cluster-info 2>/dev/null || echo "")
    
    if [[ "$cluster_info" =~ "kind" ]] || command -v kind &> /dev/null && kind get clusters 2>/dev/null | grep -q .; then
        log_info "To access ArgoCD UI (Kind cluster):"
        echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
        echo "  Then open: https://localhost:8080"
    else
        local node_port
        node_port=$(kubectl get svc argocd-server -n ${ARGOCD_NAMESPACE} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
        if [[ -n "$node_port" ]]; then
            log_info "ArgoCD UI access: http://localhost:${node_port}"
        else
            log_info "To access ArgoCD UI:"
            echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8080:443"
            echo "  Then open: https://localhost:8080"
        fi
    fi
    
    echo ""
    log_warning "Important:"
    echo "  • Monitor the deployment in ArgoCD UI"
    echo "  • The stack will create AWS resources that may incur charges"
    echo "  • Check AWS console to verify resource creation"
}

main() {
    echo -e "${GREEN}Pulumi Operator AWS - App of Apps Deployment${NC}"
    echo "==============================================="
    echo ""
    
    # Load environment variables
    load_environment
    
    # Check prerequisites
    check_prerequisites
    
    # Setup AWS credentials
    setup_aws_credentials
    
    # Deploy App of Apps
    deploy_app_of_apps
    
    # Show monitoring info
    monitor_deployment
    
    log_success "🎉 App of Apps deployment completed!"
    echo ""
    log_info "The Pulumi Operator and AWS stack are now being managed by ArgoCD"
    log_info "Check the ArgoCD UI for deployment progress and status"
}

# Handle script interruption
trap 'echo; log_error "Script interrupted!"; exit 1' INT TERM

# Run main function
main "$@"