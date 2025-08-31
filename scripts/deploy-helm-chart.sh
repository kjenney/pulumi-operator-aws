#!/bin/bash

# Deploy Pulumi AWS Resources using Helm Chart
# This script helps deploy the Helm chart with proper configuration
# It reads environment variables from .env file if available

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
CHART_PATH="./helm-chart"
RELEASE_NAME="pulumi-aws-demo"
NAMESPACE="pulumi-aws-demo"
VALUES_FILE=""
DRY_RUN=false
ENV_FILE=".env"

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE} Pulumi AWS Helm Chart Deployment${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Function to show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy AWS resources using Pulumi Kubernetes Operator via Helm

Options:
    -n, --name RELEASE_NAME     Helm release name (default: from .env or pulumi-aws-demo)
    --namespace NAMESPACE       Kubernetes namespace (default: from .env or pulumi-aws-demo)
    -f, --values VALUES_FILE    Values file for Helm chart
    --env-file ENV_FILE         Environment file to load (default: .env)
    --dry-run                   Perform a dry run without installing
    -h, --help                  Show this help message

Environment Variables (from .env file or shell):
    AWS_ACCESS_KEY_ID          AWS access key ID
    AWS_SECRET_ACCESS_KEY      AWS secret access key
    AWS_REGION                 AWS region (default: us-west-2)
    STACK_NAMESPACE            Kubernetes namespace for the stack
    OPERATOR_NAMESPACE         Kubernetes namespace for the operator
    PROJECT_NAME               Project name
    STACK_NAME                 Stack/environment name

Examples:
    $0                                          # Basic deployment using .env
    $0 -n my-stack --namespace my-ns           # Override name and namespace
    $0 -f custom-values.yaml                   # Using custom values
    $0 --env-file .env.prod                    # Using different env file
    $0 --dry-run                               # Dry run mode

EOF
}

# Function to load environment variables from .env file
load_env_file() {
    if [[ -f "$ENV_FILE" ]]; then
        print_status "Loading environment variables from $ENV_FILE"
        
        # Read the .env file and export variables
        # This handles comments and empty lines properly
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
                    print_status "Loaded $var_name=***"
                else
                    print_status "Loaded $line"
                fi
            fi
        done < "$ENV_FILE"
    else
        print_warning "Environment file $ENV_FILE not found. Using shell environment variables."
    fi
}

# Function to set default values from environment variables
set_defaults_from_env() {
    # Set release name from PROJECT_NAME if available
    if [[ -n "${PROJECT_NAME:-}" ]]; then
        RELEASE_NAME="${PROJECT_NAME}"
    fi
    
    # Set namespace from STACK_NAMESPACE if available
    if [[ -n "${STACK_NAMESPACE:-}" ]]; then
        NAMESPACE="${STACK_NAMESPACE}"
    fi
    
    print_status "Using release name: $RELEASE_NAME"
    print_status "Using namespace: $NAMESPACE"
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if kubectl is installed and connected
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        print_error "Helm is not installed or not in PATH"
        exit 1
    fi
    
    # Check kubernetes connection
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    # Check if Pulumi operator is installed
    if ! kubectl get crd stacks.pulumi.com &> /dev/null; then
        print_warning "Pulumi Kubernetes Operator CRD not found"
        print_warning "Install it with: kubectl apply -f https://github.com/pulumi/pulumi-kubernetes-operator/releases/download/v1.15.0/deploy.yaml"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    print_status "Prerequisites check completed"
}

# Function to validate environment variables
validate_env_vars() {
    print_status "Validating environment variables..."
    
    local missing_vars=()
    
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
        missing_vars+=("AWS_ACCESS_KEY_ID")
    fi
    
    if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        missing_vars+=("AWS_SECRET_ACCESS_KEY")
    fi
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        print_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            print_error "  - $var"
        done
        print_error "Please set these variables in your .env file or shell environment"
        exit 1
    fi
    
    # Validate AWS region
    AWS_REGION="${AWS_REGION:-us-west-2}"
    
    print_status "Environment variables validated"
    print_status "AWS Region: $AWS_REGION"
    print_status "Project Name: ${PROJECT_NAME:-aws-resources}"
    print_status "Stack Name: ${STACK_NAME:-dev}"
    print_status "Operator Namespace: ${OPERATOR_NAMESPACE:-pulumi-kubernetes-operator}"
}

# Function to create temporary values file with secrets and configuration
create_values_with_env() {
    local temp_values_file=$(mktemp)
    
    # Base64 encode the secrets
    local aws_access_key_b64=$(echo -n "$AWS_ACCESS_KEY_ID" | base64)
    local aws_secret_key_b64=$(echo -n "$AWS_SECRET_ACCESS_KEY" | base64)
    local aws_region_b64=$(echo -n "$AWS_REGION" | base64)
    
    # Start with base values
    if [[ -n "$VALUES_FILE" && -f "$VALUES_FILE" ]]; then
        cp "$VALUES_FILE" "$temp_values_file"
    else
        cp "$CHART_PATH/values.yaml" "$temp_values_file"
    fi
    
    # Create configuration section from environment variables
    cat >> "$temp_values_file" << EOF

# Auto-generated configuration from .env file
global:
  namespace:
    name: ${NAMESPACE}

aws:
  region: ${AWS_REGION:-us-west-2}
  credentials:
    secretName: aws-credentials
    accessKeyId: "$aws_access_key_b64"
    secretAccessKey: "$aws_secret_key_b64"
    awsRegion: "$aws_region_b64"

pulumi:
  backend:
    useLocal: true
  
  project:
    name: ${PROJECT_NAME:-aws-resources}
  
  stack:
    name: ${PROJECT_NAME:-aws-resources}
    environment: ${STACK_NAME:-dev}

# Project Configuration from environment
project:
  name: ${PROJECT_NAME:-aws-resources}
  environment: ${STACK_NAME:-dev}
  # Generate a unique bucket name using project and environment
  bucketName: ${PROJECT_NAME:-aws-resources}-${STACK_NAME:-dev}-bucket-$(date +%s)

# Operator namespace configuration
operatorNamespace: ${OPERATOR_NAMESPACE:-pulumi-kubernetes-operator}
EOF
    
    echo "$temp_values_file"
}

# Function to deploy the Helm chart
deploy_chart() {
    print_status "Preparing Helm deployment..."
    
    # Create values file with environment variables and secrets
    local values_with_env=$(create_values_with_env)
    
    print_status "Generated temporary values file with environment configuration"
    
    # Build helm command
    local helm_cmd="helm"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        helm_cmd="$helm_cmd install $RELEASE_NAME $CHART_PATH --dry-run --debug"
    else
        helm_cmd="$helm_cmd upgrade --install $RELEASE_NAME $CHART_PATH"
        helm_cmd="$helm_cmd --create-namespace --namespace $NAMESPACE"
    fi
    
    helm_cmd="$helm_cmd --values $values_with_env"
    
    print_status "Executing: $helm_cmd"
    
    # Execute the helm command
    if eval "$helm_cmd"; then
        if [[ "$DRY_RUN" == "false" ]]; then
            print_status "Helm chart deployed successfully!"
            print_status "Release name: $RELEASE_NAME"
            print_status "Namespace: $NAMESPACE"
            print_status "AWS Region: $AWS_REGION"
            print_status "Project: ${PROJECT_NAME:-aws-resources}"
            print_status "Environment: ${STACK_NAME:-dev}"
        else
            print_status "Dry run completed successfully!"
        fi
    else
        print_error "Helm deployment failed"
        cleanup "$values_with_env"
        exit 1
    fi
    
    # Clean up temporary file
    cleanup "$values_with_env"
}

# Function to show post-deployment information
show_post_deployment_info() {
    if [[ "$DRY_RUN" == "true" ]]; then
        return
    fi
    
    echo
    print_header
    print_status "Deployment completed! Here's what you can do next:"
    echo
    echo "Check the stack status:"
    echo "  kubectl get stack -n $NAMESPACE"
    echo
    echo "View the stack details:"
    echo "  kubectl describe stack ${PROJECT_NAME:-aws-resources} -n $NAMESPACE"
    echo
    echo "Monitor the logs:"
    echo "  kubectl logs -l auto.pulumi.com/component=workspace -n $NAMESPACE -f"
    echo
    echo "Check all resources:"
    echo "  kubectl get all -n $NAMESPACE"
    echo
    echo "Check secrets:"
    echo "  kubectl get secrets -n ${OPERATOR_NAMESPACE:-pulumi-kubernetes-operator}"
    echo
    echo "View AWS resources in console:"
    echo "  Region: $AWS_REGION"
    echo "  Look for resources tagged with Project: ${PROJECT_NAME:-aws-resources}"
    echo
    echo "To uninstall:"
    echo "  helm uninstall $RELEASE_NAME -n $NAMESPACE"
    echo
    echo "Environment used:"
    echo "  Environment File: $ENV_FILE"
    echo "  AWS Region: $AWS_REGION"
    echo "  Project Name: ${PROJECT_NAME:-aws-resources}"
    echo "  Stack Name: ${STACK_NAME:-dev}"
    echo "  Operator Namespace: ${OPERATOR_NAMESPACE:-pulumi-kubernetes-operator}"
    echo "  Stack Namespace: $NAMESPACE"
}

# Cleanup function
cleanup() {
    local temp_file="$1"
    if [[ -f "$temp_file" ]]; then
        rm -f "$temp_file"
        print_status "Cleaned up temporary files"
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            RELEASE_NAME="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -f|--values)
            VALUES_FILE="$2"
            shift 2
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    print_header
    
    # Validate that the chart path exists
    if [[ ! -d "$CHART_PATH" ]]; then
        print_error "Helm chart not found at: $CHART_PATH"
        exit 1
    fi
    
    # Load environment variables from .env file
    load_env_file
    
    # Set default values from environment variables
    set_defaults_from_env
    
    # Check prerequisites
    check_prerequisites
    
    # Validate environment variables (skip in dry run mode)
    if [[ "$DRY_RUN" == "false" ]]; then
        validate_env_vars
    else
        print_warning "Skipping environment validation in dry-run mode"
    fi
    
    # Deploy the chart
    deploy_chart
    
    # Show post-deployment information
    show_post_deployment_info
}

# Execute main function
main "$@"
