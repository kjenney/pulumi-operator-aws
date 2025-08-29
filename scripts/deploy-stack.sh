#!/bin/bash

# deploy-stack.sh
# Script to deploy AWS resources using Pulumi Kubernetes Operator

set -euo pipefail

# Ensure we're running from the project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Enable debug mode if DEBUG=1 is set
if [[ "${DEBUG:-0}" == "1" ]]; then
    set -x
fi

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
if [[ -n "${NAMESPACE:-}" ]] && [[ "${STACK_NAMESPACE}" == "pulumi-aws-demo" ]]; then
    STACK_NAMESPACE="${NAMESPACE}"
fi
ENV_FILE="${ENV_FILE:-.env}"
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

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1"
    fi
}

find_operator_namespace() {
    log_debug "Looking for Pulumi Kubernetes Operator..."
    local namespaces=("${OPERATOR_NAMESPACE}" "pulumi-kubernetes-operator" "pulumi-system")
    
    for ns in "${namespaces[@]}"; do
        log_debug "Checking namespace: $ns"
        if kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${ns} >/dev/null 2>&1; then
            log_debug "Found operator in namespace: $ns"
            echo "$ns"
            return 0
        fi
    done
    
    log_debug "Operator not found in any expected namespace"
    return 1
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check kubectl
    log_debug "Checking kubectl..."
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    log_debug "kubectl found: $(which kubectl)"
    
    # Check if cluster is accessible
    log_debug "Checking cluster connectivity..."
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot access Kubernetes cluster. Please ensure cluster is running and kubectl is configured."
        log_info "Current kubectl context: $(kubectl config current-context 2>/dev/null || echo 'none')"
        exit 1
    fi
    log_debug "Cluster is accessible"
    
    # Find the operator namespace
    log_debug "Finding operator namespace..."
    local found_operator_ns
    if ! found_operator_ns=$(find_operator_namespace); then
        log_error "Pulumi Kubernetes Operator is not installed."
        log_info "Available deployments:"
        kubectl get deployments --all-namespaces | grep -E "(NAME|pulumi)" || echo "  No Pulumi deployments found"
        log_info "Please run './scripts/install-operator.sh' first."
        exit 1
    fi
    
    log_info "Found Pulumi Kubernetes Operator in namespace: $found_operator_ns"
    
    # Update operator namespace if different from expected
    if [[ "$found_operator_ns" != "$OPERATOR_NAMESPACE" ]]; then
        log_info "Updating OPERATOR_NAMESPACE from $OPERATOR_NAMESPACE to $found_operator_ns"
        OPERATOR_NAMESPACE="$found_operator_ns"
    fi
    
    # Verify we're in the correct project directory
    if [[ ! -d "k8s-manifests" ]]; then
        log_error "k8s-manifests directory not found. Are you running from the project root?"
        log_error "Current directory: $(pwd)"
        log_error "Expected to find: $(pwd)/k8s-manifests/"
        exit 1
    fi
    
    # Check if environment file exists
    log_debug "Checking environment file: $ENV_FILE"
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "Environment file '$ENV_FILE' not found."
        log_info "Available files in current directory:"
        ls -la | grep -E "\\.env" || echo "  No .env files found"
        log_info "Please copy .env.example to .env and configure it:"
        log_info "  cp .env.example .env"
        log_info "  # Then edit .env with your credentials"
        exit 1
    fi
    log_debug "Environment file found: $ENV_FILE"
    
    log_success "Prerequisites check passed!"
}

load_environment() {
    log_info "Loading environment variables from ${ENV_FILE}..."
    
    # Check if file is readable
    if [[ ! -r "$ENV_FILE" ]]; then
        log_error "Cannot read environment file '$ENV_FILE'. Check file permissions."
        exit 1
    fi
    
    # Save the detected namespaces before loading environment
    local detected_operator_ns="$OPERATOR_NAMESPACE"
    local detected_stack_ns="$STACK_NAMESPACE"
    log_debug "Preserving detected namespaces: operator=$detected_operator_ns, stack=$detected_stack_ns"
    
    # Load environment variables
    set -a
    source "$ENV_FILE" || {
        log_error "Failed to source environment file '$ENV_FILE'. Check file syntax."
        exit 1
    }
    set +a
    
    # Update namespaces from environment if they were set
    OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-$detected_operator_ns}"
    STACK_NAMESPACE="${STACK_NAMESPACE:-$detected_stack_ns}"
    
    # Handle legacy NAMESPACE variable
    if [[ -n "${NAMESPACE:-}" ]]; then
        log_info "Found legacy NAMESPACE variable, using for STACK_NAMESPACE: $NAMESPACE"
        STACK_NAMESPACE="$NAMESPACE"
    fi
    
    log_info "Using namespaces: operator=$OPERATOR_NAMESPACE, stack=$STACK_NAMESPACE"
    
    # Validate required variables
    local required_vars=(
        "AWS_ACCESS_KEY_ID"
        "AWS_SECRET_ACCESS_KEY" 
        "AWS_REGION"
        "PULUMI_ACCESS_TOKEN"
    )
    
    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        else
            local var_value="${!var}"
            log_debug "$var is set (${#var_value} characters)"
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Required environment variables are missing from $ENV_FILE:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        log_info "Please ensure all required variables are set in $ENV_FILE"
        exit 1
    fi
    
    log_success "Environment variables loaded successfully!"
}

create_secrets() {
    log_info "Creating Kubernetes secrets in stack namespace: ${STACK_NAMESPACE}..."
    
    # Ensure the stack namespace exists
    log_debug "Creating namespace: $STACK_NAMESPACE"
    kubectl create namespace ${STACK_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f - || {
        log_error "Failed to create namespace $STACK_NAMESPACE"
        exit 1
    }
    
    # Create AWS credentials secret in stack namespace
    log_debug "Creating AWS credentials secret..."
    kubectl create secret generic aws-credentials \
        --namespace=${STACK_NAMESPACE} \
        --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        --from-literal=AWS_REGION="${AWS_REGION}" \
        --dry-run=client -o yaml | kubectl apply -f - || {
        log_error "Failed to create AWS credentials secret"
        exit 1
    }
    
    # Create Pulumi access token secret in stack namespace
    log_debug "Creating Pulumi access token secret..."
    kubectl create secret generic pulumi-access-token \
        --namespace=${STACK_NAMESPACE} \
        --from-literal=accessToken="${PULUMI_ACCESS_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f - || {
        log_error "Failed to create Pulumi access token secret"
        exit 1
    }
    
    log_success "Secrets created successfully in namespace: ${STACK_NAMESPACE}!"
}

prepare_manifests() {
    log_info "Preparing Kubernetes manifests for namespace: ${STACK_NAMESPACE}..." >&2
    
    # Verify we're in the correct directory
    if [[ ! -d "k8s-manifests" ]]; then
        log_error "k8s-manifests directory not found. Are you running from the project root?" >&2
        log_error "Current directory: $(pwd)" >&2
        exit 1
    fi
    
    # Create temporary directory for processed manifests
    local temp_dir="/tmp/pulumi-manifests-$$"
    if ! mkdir -p "$temp_dir"; then
        log_error "Failed to create temporary directory: $temp_dir" >&2
        exit 1
    fi
    log_debug "Created temporary directory: $temp_dir" >&2
    
    # Process namespace template if it exists
    if [[ -f "k8s-manifests/namespace.yaml.template" ]]; then
        log_debug "Processing namespace template..." >&2
        if ! sed "s/__STACK_NAMESPACE__/${STACK_NAMESPACE}/g" k8s-manifests/namespace.yaml.template > "$temp_dir/namespace.yaml"; then
            log_error "Failed to process namespace template" >&2
            rm -rf "$temp_dir"
            exit 1
        fi
    elif [[ -f "k8s-manifests/namespace.yaml" ]]; then
        log_debug "Using existing namespace manifest..." >&2
        if ! cp k8s-manifests/namespace.yaml "$temp_dir/namespace.yaml"; then
            log_error "Failed to copy namespace manifest" >&2
            rm -rf "$temp_dir"
            exit 1
        fi
    fi
    
    # Process service account template
    if [[ -f "k8s-manifests/service-account.yaml.template" ]]; then
        log_debug "Processing service account template..." >&2
        if ! sed "s/__STACK_NAMESPACE__/${STACK_NAMESPACE}/g" k8s-manifests/service-account.yaml.template > "$temp_dir/service-account.yaml"; then
            log_error "Failed to process service account template" >&2
            rm -rf "$temp_dir"
            exit 1
        fi
    elif [[ -f "k8s-manifests/service-account.yaml" ]]; then
        log_debug "Using existing service account manifest..." >&2
        if ! cp k8s-manifests/service-account.yaml "$temp_dir/service-account.yaml"; then
            log_error "Failed to copy service account manifest" >&2
            rm -rf "$temp_dir"
            exit 1
        fi
    else
        log_error "No service account manifest found" >&2
        log_error "Available files in k8s-manifests:" >&2
        ls -la k8s-manifests/ >&2 || log_error "Cannot list k8s-manifests directory" >&2
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Process stack template
    if [[ -f "k8s-manifests/pulumi-stack.yaml.template" ]]; then
        log_debug "Processing stack template..." >&2
        if ! sed "s/__STACK_NAMESPACE__/${STACK_NAMESPACE}/g" k8s-manifests/pulumi-stack.yaml.template > "$temp_dir/pulumi-stack.yaml"; then
            log_error "Failed to process stack template" >&2
            rm -rf "$temp_dir"
            exit 1
        fi
    elif [[ -f "k8s-manifests/pulumi-stack.yaml" ]]; then
        log_debug "Processing existing stack manifest..." >&2
        if ! sed "s/namespace: .*/namespace: ${STACK_NAMESPACE}/g" k8s-manifests/pulumi-stack.yaml > "$temp_dir/pulumi-stack.yaml"; then
            log_error "Failed to process stack manifest" >&2
            rm -rf "$temp_dir"
            exit 1
        fi
    else
        log_error "No stack manifest found" >&2
        log_error "Available files in k8s-manifests:" >&2
        ls -la k8s-manifests/ >&2 || log_error "Cannot list k8s-manifests directory" >&2
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Copy other manifests if they exist
    if [[ -f "k8s-manifests/pulumi-program-configmap.yaml" ]]; then
        log_debug "Copying configmap manifest..." >&2
        if ! cp k8s-manifests/pulumi-program-configmap.yaml "$temp_dir/"; then
            log_error "Failed to copy configmap manifest" >&2
            rm -rf "$temp_dir"
            exit 1
        fi
    fi
    
    # Verify all expected files were created
    log_debug "Verifying manifest files were created in $temp_dir:" >&2
    if ! ls -la "$temp_dir" >&2; then
        log_error "Failed to list files in temporary directory" >&2
        exit 1
    fi
    
    echo "$temp_dir"
}

deploy_manifests() {
    log_info "Deploying Kubernetes manifests..."
    
    # Prepare manifests in temporary directory
    local temp_dir
    temp_dir=$(prepare_manifests)
    
    if [[ -z "$temp_dir" ]] || [[ ! -d "$temp_dir" ]]; then
        log_error "Failed to prepare manifests - temporary directory not created"
        exit 1
    fi
    
    # Check if manifest files exist in temp directory
    local manifests=()
    
    # Add namespace if it exists
    if [[ -f "$temp_dir/namespace.yaml" ]]; then
        manifests+=("$temp_dir/namespace.yaml")
    fi
    
    # Add required manifests
    manifests+=(
        "$temp_dir/service-account.yaml"
        "$temp_dir/pulumi-stack.yaml"
    )
    
    # Add configmap if it exists
    if [[ -f "$temp_dir/pulumi-program-configmap.yaml" ]]; then
        manifests+=("$temp_dir/pulumi-program-configmap.yaml")
    fi
    
    for manifest in "${manifests[@]}"; do
        if [[ ! -f "$manifest" ]]; then
            log_error "Manifest file not found: $manifest"
            log_info "Available files in temp directory:"
            ls -la "$temp_dir" || echo "  Directory not found"
            rm -rf "$temp_dir"
            exit 1
        fi
    done
    
    # Apply Namespace first if it exists
    if [[ -f "$temp_dir/namespace.yaml" ]]; then
        log_debug "Applying Namespace..."
        kubectl apply -f "$temp_dir/namespace.yaml" || {
            log_error "Failed to apply Namespace"
            rm -rf "$temp_dir"
            exit 1
        }
    fi
    
    # Apply Service Account second
    log_debug "Applying Service Account..."
    kubectl apply -f "$temp_dir/service-account.yaml" || {
        log_error "Failed to apply Service Account"
        rm -rf "$temp_dir"
        exit 1
    }
    
    # Apply ConfigMap if it exists
    if [[ -f "$temp_dir/pulumi-program-configmap.yaml" ]]; then
        log_debug "Applying ConfigMap..."
        kubectl apply -f "$temp_dir/pulumi-program-configmap.yaml" || {
            log_error "Failed to apply ConfigMap"
            rm -rf "$temp_dir"
            exit 1
        }
    fi
    
    # Apply Stack manifest
    log_debug "Applying Stack manifest..."
    kubectl apply -f "$temp_dir/pulumi-stack.yaml" || {
        log_error "Failed to apply Stack manifest"
        rm -rf "$temp_dir"
        exit 1
    }
    
    # Cleanup temporary directory
    rm -rf "$temp_dir"
    
    log_success "Kubernetes manifests deployed successfully!"
}

wait_for_stack() {
    log_info "Waiting for Pulumi stack to be ready in namespace: ${STACK_NAMESPACE}..."
    
    local timeout=900  # 15 minutes
    local interval=15
    local elapsed=0
    
    # First, let's verify the stack name and namespace are correct
    log_debug "Looking for stack '$STACK_NAME' in namespace '$STACK_NAMESPACE'"
    
    # Check if we can find the stack in the expected namespace
    while [[ $elapsed -lt 60 ]] && ! kubectl get stack ${STACK_NAME} -n ${STACK_NAMESPACE} >/dev/null 2>&1; do
        log_info "Waiting for stack to be created... (${elapsed}s elapsed)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    if ! kubectl get stack ${STACK_NAME} -n ${STACK_NAMESPACE} >/dev/null 2>&1; then
        log_error "Stack '${STACK_NAME}' not found in namespace '${STACK_NAMESPACE}' after waiting"
        log_info "Searching for stacks in all namespaces..."
        
        # Look for any stacks that might match
        local all_stacks
        all_stacks=$(kubectl get stacks --all-namespaces --no-headers 2>/dev/null || echo "")
        
        if [[ -n "$all_stacks" ]]; then
            log_info "Found the following stacks:"
            echo "$all_stacks"
        else
            log_error "No stacks found in any namespace"
        fi
        return 1
    fi
    
    log_info "Monitoring stack '${STACK_NAME}' in namespace '${STACK_NAMESPACE}'"
    
    # Reset elapsed time for the actual wait
    elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        # Check the Ready condition in the status.conditions array
        local ready_condition
        ready_condition=$(kubectl get stack ${STACK_NAME} -n ${STACK_NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")]}' 2>/dev/null || echo "")
        
        if [[ -n "$ready_condition" ]]; then
            # Extract the status and message from the Ready condition
            local ready_status
            local ready_message
            ready_status=$(echo "$ready_condition" | jq -r '.status' 2>/dev/null || echo "")
            ready_message=$(echo "$ready_condition" | jq -r '.message' 2>/dev/null || echo "")
            
            log_debug "Ready condition - Status: $ready_status, Message: $ready_message"
            
            if [[ "$ready_status" == "True" ]]; then
                log_success "Pulumi stack deployment succeeded!"
                log_info "Message: $ready_message"
                return 0
            elif [[ "$ready_status" == "False" ]]; then
                log_error "Pulumi stack deployment failed!"
                log_error "Message: $ready_message"
                kubectl describe stack ${STACK_NAME} -n ${STACK_NAMESPACE}
                echo ""
                log_info "Stack events:"
                kubectl get events -n ${STACK_NAMESPACE} --field-selector involvedObject.name=${STACK_NAME} --sort-by='.lastTimestamp' 2>/dev/null || true
                return 1
            else
                log_info "Stack Ready condition status: $ready_status (${elapsed}s elapsed)"
                if [[ -n "$ready_message" ]]; then
                    log_info "Message: $ready_message"
                fi
            fi
        else
            log_info "Waiting for Ready condition to appear... (${elapsed}s elapsed)"
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout waiting for stack deployment to complete"
    kubectl describe stack ${STACK_NAME} -n ${STACK_NAMESPACE}
    return 1
}

display_stack_info() {
    log_info "Stack deployment information:"
    echo "============================="
    
    # Get stack status
    kubectl get stack ${STACK_NAME} -n ${STACK_NAMESPACE} || {
        log_error "Failed to get stack status"
        return 1
    }
    echo ""
    
    # Get stack details
    log_info "Stack details:"
    kubectl describe stack ${STACK_NAME} -n ${STACK_NAMESPACE} || {
        log_warning "Failed to describe stack"
    }
    echo ""
    
    # Get stack outputs
    log_info "Stack outputs:"
    local outputs
    outputs=$(kubectl get stack ${STACK_NAME} -n ${STACK_NAMESPACE} -o jsonpath='{.status.outputs}' 2>/dev/null || echo "{}")
    
    if [[ "$outputs" != "{}" ]] && [[ "$outputs" != "" ]] && [[ "$outputs" != "null" ]]; then
        echo "$outputs" | jq '.' 2>/dev/null || echo "$outputs"
    else
        log_warning "No outputs available yet. Stack may still be deploying or outputs not configured."
    fi
    
    # Show workspace information if available
    log_info "Workspace information:"
    kubectl get pods -n ${STACK_NAMESPACE} -l pulumi.com/stack-name=${STACK_NAME} 2>/dev/null || log_info "No workspace pods found"
}

monitor_deployment() {
    log_info "Monitoring stack deployment..."
    log_info "Operator namespace: ${OPERATOR_NAMESPACE}"
    log_info "Stack namespace: ${STACK_NAMESPACE}"
    
    # Show real-time logs from the operator
    log_info "Recent operator logs:"
    kubectl logs deployment/pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE} --tail=20 2>/dev/null || log_warning "Could not fetch operator logs"
    echo ""
    
    # Check if there are any workspace pods for this stack
    local workspace_pods
    workspace_pods=$(kubectl get pods -n ${STACK_NAMESPACE} -l pulumi.com/stack-name=${STACK_NAME} --no-headers 2>/dev/null | wc -l)
    
    if [[ "$workspace_pods" -gt 0 ]]; then
        log_info "Found workspace pod(s) for stack. Following workspace logs..."
        kubectl logs -f -l pulumi.com/stack-name=${STACK_NAME} -n ${STACK_NAMESPACE} &
        local logs_pid=$!
        
        # Wait for stack completion with timeout
        (
            sleep 30
            kill $logs_pid 2>/dev/null || true
        ) &
        local timeout_pid=$!
        
        wait_for_stack
        local stack_result=$?
        
        # Stop following logs and timeout
        kill $logs_pid 2>/dev/null || true
        kill $timeout_pid 2>/dev/null || true
        wait $logs_pid 2>/dev/null || true
        wait $timeout_pid 2>/dev/null || true
        
        return $stack_result
    else
        log_info "No workspace pods found yet. Following operator logs..."
        kubectl logs -f deployment/pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE} &
        local logs_pid=$!
        
        # Wait for stack with timeout
        (
            sleep 35  # 5 seconds initial wait + 30 seconds timeout
            kill $logs_pid 2>/dev/null || true
        ) &
        local timeout_pid=$!
        
        sleep 5
        wait_for_stack
        local stack_result=$?
        
        # Stop following logs and timeout
        kill $logs_pid 2>/dev/null || true
        kill $timeout_pid 2>/dev/null || true
        wait $logs_pid 2>/dev/null || true
        wait $timeout_pid 2>/dev/null || true
        
        return $stack_result
    fi
}

validate_aws_resources() {
    log_info "Validating AWS resources..."
    
    # Check if AWS CLI is available for validation
    if command -v aws &> /dev/null; then
        log_info "Using AWS CLI to validate resources..."
        
        # List S3 buckets containing our project name
        local buckets
        buckets=$(aws s3api list-buckets --query "Buckets[?contains(Name, 'pulumi-aws-demo')].Name" --output text 2>/dev/null || echo "")
        
        if [[ -n "$buckets" ]]; then
            log_success "Found S3 buckets: $buckets"
        else
            log_warning "No matching S3 buckets found (this may be normal if using custom names)"
        fi
        
        # List VPCs with our tags
        local vpcs
        vpcs=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=pulumi-aws-demo" --query "Vpcs[].VpcId" --output text 2>/dev/null || echo "")
        
        if [[ -n "$vpcs" ]]; then
            log_success "Found VPCs: $vpcs"
        else
            log_warning "No matching VPCs found (this may be normal if using custom tags)"
        fi
    else
        log_info "AWS CLI not found. Skipping AWS resource validation."
        log_info "You can manually check your AWS console to verify resource creation."
    fi
}

display_next_steps() {
    log_info "Deployment completed successfully!"
    echo ""
    log_info "Namespace Information:"
    echo "- Operator running in: ${OPERATOR_NAMESPACE}"
    echo "- Stack deployed to: ${STACK_NAMESPACE}"
    echo ""
    log_info "Next steps:"
    echo "1. Check the AWS console to verify your resources were created"
    echo "2. Monitor the stack: kubectl get stack ${STACK_NAME} -n ${STACK_NAMESPACE}"
    echo "3. View stack outputs: kubectl get stack ${STACK_NAME} -n ${STACK_NAMESPACE} -o jsonpath='{.status.outputs}' | jq ."
    echo "4. Check workspace pods: kubectl get pods -n ${STACK_NAMESPACE} -l pulumi.com/stack-name=${STACK_NAME}"
    echo "5. Check operator logs: kubectl logs -f deployment/pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE}"
    echo ""
    log_info "To clean up resources:"
    echo "   ./scripts/cleanup.sh"
    echo ""
    log_warning "Remember: AWS resources will incur costs. Clean up when done!"
}

show_debug_info() {
    echo ""
    log_info "Debug Information:"
    echo "=================="
    echo "Current directory: $(pwd)"
    echo "Environment file: $ENV_FILE (exists: $([ -f "$ENV_FILE" ] && echo "yes" || echo "no"))"
    echo "Operator namespace: $OPERATOR_NAMESPACE"
    echo "Stack namespace: $STACK_NAMESPACE"
    echo "Stack name: $STACK_NAME"
    echo "Kubectl context: $(kubectl config current-context 2>/dev/null || echo 'none')"
    echo ""
    log_info "Available namespaces:"
    kubectl get namespaces | head -10
    echo ""
    log_info "Pulumi-related resources:"
    kubectl get all --all-namespaces | grep -i pulumi || echo "  No Pulumi resources found"
}

main() {
    log_info "Deploying AWS resources using Pulumi Kubernetes Operator..."
    echo "==========================================================="
    log_info "Project directory: $(pwd)"
    
    # Show debug info if DEBUG=1
    if [[ "${DEBUG:-0}" == "1" ]]; then
        show_debug_info
    fi
    
    check_prerequisites
    load_environment
    create_secrets
    deploy_manifests
    
    log_debug "About to monitor deployment with operator namespace: $OPERATOR_NAMESPACE, stack namespace: $STACK_NAMESPACE"
    monitor_deployment
    
    if [[ $? -eq 0 ]]; then
        display_stack_info
        validate_aws_resources
        display_next_steps
        log_success "AWS resources deployment completed successfully!"
    else
        log_error "AWS resources deployment failed!"
        log_info "Check the logs above for details. You can also run:"
        echo "  kubectl describe stack ${STACK_NAME} -n ${STACK_NAMESPACE}"
        echo "  kubectl logs deployment/pulumi-kubernetes-operator-controller-manager -n ${OPERATOR_NAMESPACE}"
        echo "  kubectl get pods -n ${STACK_NAMESPACE} -l pulumi.com/stack-name=${STACK_NAME}"
        
        if [[ "${DEBUG:-0}" != "1" ]]; then
            log_info ""
            log_info "For more detailed debugging, run:"
            log_info "  DEBUG=1 ./scripts/deploy-stack.sh"
        fi
        
        exit 1
    fi
}

# Handle script interruption
trap 'log_error "Script interrupted"; exit 130' INT TERM

# Run main function
main "$@"
