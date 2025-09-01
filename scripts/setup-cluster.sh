#!/bin/bash

# setup-cluster.sh
# Script to set up a local Kubernetes cluster for Pulumi Operator demo

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

load_env_file() {
    local env_file="${ENV_FILE:-.env}"
    if [[ -f "$env_file" ]]; then
        log_info "Loading environment variables from $env_file"
        # Read the .env file and export variables
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments
            if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            
            # Remove inline comments and trim whitespace
            line=$(echo "$line" | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            
            # Skip if line is empty after processing
            if [[ -z "$line" ]]; then
                continue
            fi
            
            # Export the variable if it contains =
            if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                export "$line"
                # Extract variable name for logging (without value for security)
                var_name=$(echo "$line" | cut -d'=' -f1)
                if [[ "$var_name" =~ (ACCESS_KEY|SECRET|TOKEN|PASSWORD) ]]; then
                    log_info "Loaded $var_name=***"
                else
                    log_info "Loaded $line"
                fi
            fi
        done < "$env_file"
    else
        log_warning "Environment file $env_file not found. Using default values."
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running. Please start Docker first."
        exit 1
    fi
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    
    log_success "Prerequisites check passed!"
}

install_kind() {
    if command -v kind &> /dev/null; then
        log_info "kind is already installed: $(kind version)"
        return 0
    fi
    
    log_info "Installing kind ${KIND_VERSION}..."
    
    # Detect OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH=amd64 ;;
        arm64) ARCH=arm64 ;;
        aarch64) ARCH=arm64 ;;
        *) log_error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    
    # Download and install kind
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
    
    log_success "kind ${KIND_VERSION} installed successfully!"
}

create_kind_cluster() {
    # Check if cluster already exists
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        log_warning "Cluster '${CLUSTER_NAME}' already exists. Deleting..."
        kind delete cluster --name="${CLUSTER_NAME}"
    fi
    
    log_info "Creating kind cluster '${CLUSTER_NAME}'..."
    
    # Create kind cluster configuration
    cat <<EOF > /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 8080
    protocol: TCP
  - containerPort: 443
    hostPort: 8443
    protocol: TCP
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
EOF
    
    # Create the cluster
    kind create cluster --config=/tmp/kind-config.yaml --wait=300s
    
    # Clean up config file
    rm /tmp/kind-config.yaml
    
    log_success "Kind cluster '${CLUSTER_NAME}' created successfully!"
}

configure_kubectl() {
    log_info "Configuring kubectl..."
    
    # Set kubectl context
    kubectl cluster-info --context kind-${CLUSTER_NAME}
    
    # Wait for nodes to be ready
    log_info "Waiting for nodes to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    log_success "kubectl configured and cluster is ready!"
}

install_ingress_controller() {
    log_info "Installing NGINX Ingress Controller..."
    
    # Apply NGINX Ingress Controller manifests for kind
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
    
    # Wait for the ingress controller to be ready
    log_info "Waiting for ingress controller to be ready..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=300s
    
    log_success "NGINX Ingress Controller installed successfully!"
}

load_pulumi_image() {
    if [[ -f "pulumi-image.tar" ]]; then
        log_info "Loading Pulumi image..."
        docker cp pulumi-image.tar ${CLUSTER_NAME}-control-plane:/pulumi-image.tar
        docker exec ${CLUSTER_NAME}-control-plane ctr -n k8s.io images import /pulumi-image.tar
        log_success "Pulumi image loaded successfully!"
    else
        log_info "No pulumi-image.tar found, skipping image load"
    fi
}

display_cluster_info() {
    log_info "Cluster Information:"
    echo "===================="
    echo "Cluster Name: ${CLUSTER_NAME}"
    echo "Kubernetes Version: $(kubectl version --short --client)"
    echo "Nodes:"
    kubectl get nodes -o wide
    echo ""
    echo "Cluster Context: kind-${CLUSTER_NAME}"
    echo ""
    log_info "To interact with this cluster, use:"
    echo "  kubectl --context kind-${CLUSTER_NAME} get nodes"
    echo ""
    log_info "To delete this cluster when done:"
    echo "  kind delete cluster --name ${CLUSTER_NAME}"
}

main() {
    log_info "Setting up local Kubernetes cluster for Pulumi Operator demo..."
    echo "=============================================================="
    
    # Load environment variables from .env file
    load_env_file
    
    # Set configuration variables with defaults
    CLUSTER_NAME="${CLUSTER_NAME:-pulumi-aws}"
    KIND_VERSION="${KIND_VERSION:-v0.30.0}"
    
    log_info "Using cluster name: $CLUSTER_NAME"
    
    check_prerequisites
    install_kind
    create_kind_cluster
    configure_kubectl
    install_ingress_controller
    load_pulumi_image
    display_cluster_info
    
    log_success "Cluster setup completed successfully!"
    echo ""
    log_info "Next steps:"
    echo "1. Run './scripts/install-operator.sh' to install the Pulumi Kubernetes Operator"
    echo "2. Configure your AWS credentials in .env file"
    echo "3. Run './scripts/deploy-stack.sh' to deploy AWS resources"
}

# Show usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Set up a local Kubernetes cluster for Pulumi Operator demo

Options:
    --env-file ENV_FILE     Environment file to load (default: .env)
    -h, --help              Show this help message

Environment Variables (from .env file or shell):
    CLUSTER_NAME           Kubernetes cluster name (default: pulumi-aws)
    KIND_VERSION           kind version to install (default: v0.30.0)

Examples:
    $0                            # Basic setup using .env
    $0 --env-file .env.prod       # Using different env file

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Run main function
main "$@"
