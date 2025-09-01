#!/bin/bash

# quickstart.sh
# Quick start script to set up the entire Pulumi Kubernetes Operator AWS demo
# This script runs setup-cluster.sh, install-operator.sh, and deploy-stack.sh in sequence

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

log_step() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if required scripts exist
check_scripts() {
    local scripts=("setup-cluster.sh" "install-operator.sh" "deploy-stack.sh")
    
    for script in "${scripts[@]}"; do
        if [[ ! -f "${SCRIPT_DIR}/${script}" ]]; then
            log_error "Required script not found: ${script}"
            log_error "Please ensure all scripts are present in the scripts directory"
            exit 1
        fi
        
        if [[ ! -x "${SCRIPT_DIR}/${script}" ]]; then
            log_info "Making ${script} executable..."
            chmod +x "${SCRIPT_DIR}/${script}"
        fi
    done
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing_tools=()
    
    # Check for required tools
    if ! command -v kind &> /dev/null; then
        missing_tools+=("kind")
    fi
    
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    fi
    
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools and try again"
        exit 1
    fi
    
    log_success "All required tools are available"
}

# Check environment variables
check_environment() {
    log_info "Checking environment configuration..."
    
    local env_file="${SCRIPT_DIR}/../.env"
    if [[ -f "$env_file" ]]; then
        log_success "Found .env file: $env_file"
    else
        log_warning "No .env file found. Using default values."
        log_info "You can create a .env file to customize the configuration"
    fi
}

# Run a script with error handling
run_script() {
    local script_name="$1"
    local script_path="${SCRIPT_DIR}/${script_name}"
    
    log_step "Running ${script_name}..."
    
    if ! bash "${script_path}"; then
        log_error "${script_name} failed!"
        log_error "Check the output above for details"
        
        # Offer to continue or exit
        echo ""
        read -p "Do you want to continue with the next step anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Quickstart aborted due to ${script_name} failure"
            exit 1
        else
            log_warning "Continuing despite ${script_name} failure..."
        fi
    else
        log_success "${script_name} completed successfully!"
    fi
}

# Main function
main() {
    echo -e "${GREEN}Pulumi Kubernetes Operator AWS Demo - Quickstart${NC}"
    echo "=================================================="
    echo ""
    log_info "This script will:"
    echo "  1. Set up a local Kubernetes cluster (kind)"
    echo "  2. Optionally install ArgoCD for GitOps"
    echo "  3. Deploy either via GitOps (App of Apps) or direct installation"
    echo "     • GitOps: ArgoCD manages Pulumi Operator + AWS stack"  
    echo "     • Direct: Traditional script-based installation"
    echo ""
    log_warning "This will create AWS resources that may incur charges"
    echo ""
    
    # Pre-flight checks
    check_scripts
    check_prerequisites
    check_environment
    
    log_step "Starting Pulumi Kubernetes Operator AWS Demo Setup"
    
    # Step 1: Setup cluster
    run_script "setup-cluster.sh"
    
    # Step 2: Optional ArgoCD installation
    echo ""
    run_script "install-argocd.sh"
    argocd_installed=true
    run_script "deploy-app-of-apps.sh"
    gitops_deployed=true
    
    # Success message
    echo ""
    log_success "🎉 Quickstart completed successfully!"
    echo ""
    log_info "What was set up:"
    echo "  ✓ Local Kubernetes cluster (kind)"
    
    if [[ "${argocd_installed:-false}" == true ]]; then
        echo "  ✓ ArgoCD for GitOps management"
    fi
    
    if [[ "${gitops_deployed:-false}" == true ]]; then
        echo "  ✓ App of Apps pattern deployment"
        echo "  ✓ Pulumi Kubernetes Operator (via GitOps)"
        echo "  ✓ AWS resources stack (via GitOps)"
    elif [[ "${traditional_deployment:-false}" == true ]]; then
        echo "  ✓ Pulumi Kubernetes Operator (direct installation)"
        echo "  ✓ AWS resources stack (direct deployment)"
    fi
    echo ""
    log_info "Next steps:"
    
    if [[ "${gitops_deployed:-false}" == true ]]; then
        echo "  • Monitor GitOps deployments: kubectl get applications -n argocd"
        echo "  • Access ArgoCD UI (see credentials in argocd-credentials.txt)"
        echo "  • Wait for stack deployment: kubectl get stacks -n pulumi-aws-demo -w"
        echo "  • Check workspace pod logs: kubectl logs -n pulumi-aws-demo -l pulumi.com/stack-name=aws-resources -f"
    elif [[ "${traditional_deployment:-false}" == true ]]; then
        echo "  • Check the stack status: kubectl get stacks -n pulumi-aws-demo"
        echo "  • View workspace pod logs: kubectl logs -n pulumi-aws-demo -l pulumi.com/stack-name=aws-resources"
        if [[ "${argocd_installed:-false}" == true ]]; then
            echo "  • Access ArgoCD UI (see credentials in argocd-credentials.txt)"
            echo "  • Optionally migrate to GitOps: ./scripts/deploy-app-of-apps.sh"
        fi
    fi
    
    echo "  • Check AWS console for created resources"
    echo "  • When done, run: ./scripts/cleanup.sh"
    echo ""
    log_warning "Remember: AWS resources are running and may incur charges!"
    log_info "Use the cleanup script when you're done with the demo"
}

# Handle script interruption
trap 'echo; log_error "Script interrupted!"; exit 1' INT TERM

# Run main function
main "$@"