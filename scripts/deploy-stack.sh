#!/bin/bash

# deploy-stack.sh
# Script to deploy AWS resources using Pulumi Kubernetes Operator

set -euo pipefail

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

# Configuration
NAMESPACE="${NAMESPACE:-pulumi-kubernetes-operator}"
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
    local namespaces=("pulumi-kubernetes-operator" "pulumi-system")
    
    for ns in "${namespaces[@]}"; do
        log_debug "Checking namespace: $ns"
        if kubectl get deployment pulumi-kubernetes-operator-controller-manager -n ${ns} >/dev/null 2>&1; then
            log_debug "Found operator in namespace: $ns"
            echo "$ns"
            return 0
        fi
    done
    
    log_debug "Operator not found in any namespace"
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
    local operator_ns
    if ! operator_ns=$(find_operator_namespace); then
        log_error "Pulumi Kubernetes Operator is not installed."
        log_info "Available deployments:"
        kubectl get deployments --all-namespaces | grep -E "(NAME|pulumi)" || echo "  No Pulumi deployments found"
        log_info "Please run './scripts/install-operator.sh' first."
        exit 1
    fi
    
    log_info "Found Pulumi Kubernetes Operator in namespace: $operator_ns"
    
    # Update namespace if different
    if [[ "$operator_ns" != "$NAMESPACE" ]]; then
        log_info "Using operator namespace: $operator_ns"
        NAMESPACE="$operator_ns"
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
    
    # Save the detected namespace before loading environment
    local detected_namespace="$NAMESPACE"
    log_debug "Preserving detected namespace: $detected_namespace"
    
    # Load environment variables
    set -a
    source "$ENV_FILE" || {
        log_error "Failed to source environment file '$ENV_FILE'. Check file syntax."
        exit 1
    }
    set +a
    
    # Restore the detected namespace if it was overridden by the env file
    if [[ "$NAMESPACE" != "$detected_namespace" ]]; then
        log_info "Environment file tried to set NAMESPACE to '$NAMESPACE', but using detected namespace: $detected_namespace"
        NAMESPACE="$detected_namespace"
    fi
    
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
    log_info "Creating Kubernetes secrets for AWS credentials and Pulumi access token..."
    
    # Ensure the namespace exists
    log_debug "Creating namespace: $NAMESPACE"
    kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f - || {
        log_error "Failed to create namespace $NAMESPACE"
        exit 1
    }
    
    # Create AWS credentials secret
    log_debug "Creating AWS credentials secret..."
    kubectl create secret generic aws-credentials \
        --namespace=${NAMESPACE} \
        --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        --from-literal=AWS_REGION="${AWS_REGION}" \
        --dry-run=client -o yaml | kubectl apply -f - || {
        log_error "Failed to create AWS credentials secret"
        exit 1
    }
    
    # Create Pulumi access token secret
    log_debug "Creating Pulumi access token secret..."
    kubectl create secret generic pulumi-access-token \
        --namespace=${NAMESPACE} \
        --from-literal=accessToken="${PULUMI_ACCESS_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f - || {
        log_error "Failed to create Pulumi access token secret"
        exit 1
    }
    
    log_success "Secrets created successfully!"
}

deploy_manifests() {
    log_info "Deploying Kubernetes manifests..."
    
    # Check if manifest files exist
    local manifests=(
        "k8s-manifests/service-account.yaml"
        "k8s-manifests/pulumi-program-configmap.yaml"
        "k8s-manifests/pulumi-stack.yaml"
    )
    
    for manifest in "${manifests[@]}"; do
        if [[ ! -f "$manifest" ]]; then
            log_error "Manifest file not found: $manifest"
            log_info "Available files in k8s-manifests/:"
            ls -la k8s-manifests/ || echo "  Directory not found"
            exit 1
        fi
    done
    
    # Apply Service Account first
    log_debug "Applying Service Account..."
    kubectl apply -f k8s-manifests/service-account.yaml || {
        log_error "Failed to apply Service Account"
        exit 1
    }
    
    # Apply ConfigMap with Pulumi program
    log_debug "Applying ConfigMap..."
    kubectl apply -f k8s-manifests/pulumi-program-configmap.yaml || {
        log_error "Failed to apply ConfigMap"
        exit 1
    }
    
    # Update the Stack manifest with the correct namespace if needed
    if [[ "$NAMESPACE" != "pulumi-system" ]]; then
        log_info "Updating Stack manifest for namespace: $NAMESPACE"
        sed "s/namespace: pulumi-system/namespace: ${NAMESPACE}/g" k8s-manifests/pulumi-stack.yaml > /tmp/pulumi-stack-updated.yaml
        kubectl apply -f /tmp/pulumi-stack-updated.yaml || {
            log_error "Failed to apply updated Stack manifest"
            rm -f /tmp/pulumi-stack-updated.yaml
            exit 1
        }
        rm -f /tmp/pulumi-stack-updated.yaml
    else
        log_debug "Applying Stack manifest..."
        kubectl apply -f k8s-manifests/pulumi-stack.yaml || {
            log_error "Failed to apply Stack manifest"
            exit 1
        }
    fi
    
    log_success "Kubernetes manifests deployed successfully!"
}

wait_for_stack() {
    log_info "Waiting for Pulumi stack to be ready..."
    
    local timeout=900  # 15 minutes
    local interval=15
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(kubectl get stack ${STACK_NAME} -n ${NAMESPACE} -o jsonpath='{.status.lastUpdate.state}' 2>/dev/null || echo "")
        
        case "$status" in
            "succeeded")
                log_success "Pulumi stack deployment succeeded!"
                return 0
                ;;
            "failed")
                log_error "Pulumi stack deployment failed!"
                kubectl describe stack ${STACK_NAME} -n ${NAMESPACE}
                echo ""
                log_info "Stack events:"
                kubectl get events -n ${NAMESPACE} --field-selector involvedObject.name=${STACK_NAME} --sort-by='.lastTimestamp' 2>/dev/null || true
                return 1
                ;;
            "running"|"updating")
                log_info "Stack deployment in progress... Status: $status (${elapsed}s elapsed)"
                ;;
            "")
                log_info "Waiting for stack to start... (${elapsed}s elapsed)"
                ;;
            *)
                log_info "Stack status: $status (${elapsed}s elapsed)"
                ;;
        esac
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout waiting for stack deployment to complete"
    return 1
}

display_stack_info() {
    log_info "Stack deployment information:"
    echo "============================="
    
    # Get stack status
    kubectl get stack ${STACK_NAME} -n ${NAMESPACE} || {
        log_error "Failed to get stack status"
        return 1
    }
    echo ""
    
    # Get stack details
    log_info "Stack details:"
    kubectl describe stack ${STACK_NAME} -n ${NAMESPACE} || {
        log_warning "Failed to describe stack"
    }
    echo ""
    
    # Get stack outputs
    log_info "Stack outputs:"
    local outputs
    outputs=$(kubectl get stack ${STACK_NAME} -n ${NAMESPACE} -o jsonpath='{.status.outputs}' 2>/dev/null || echo "{}")
    
    if [[ "$outputs" != "{}" ]] && [[ "$outputs" != "" ]] && [[ "$outputs" != "null" ]]; then
        echo "$outputs" | jq '.' 2>/dev/null || echo "$outputs"
    else
        log_warning "No outputs available yet. Stack may still be deploying or outputs not configured."
    fi
    
    # Show workspace information if available
    log_info "Workspace information:"
    kubectl get pods -n ${NAMESPACE} -l pulumi.com/stack-name=${STACK_NAME} 2>/dev/null || log_info "No workspace pods found"
}

monitor_deployment() {
    log_info "Monitoring stack deployment..."
    log_debug "Using namespace for monitoring: $NAMESPACE"
    
    # Double-check the operator namespace to be sure
    local operator_ns
    if operator_ns=$(find_operator_namespace); then
        log_debug "Confirmed operator in namespace: $operator_ns"
        NAMESPACE="$operator_ns"
    fi
    
    # Show real-time logs from the operator
    log_info "Recent operator logs:"
    kubectl logs deployment/pulumi-kubernetes-operator-controller-manager -n ${NAMESPACE} --tail=20 2>/dev/null || log_warning "Could not fetch operator logs"
    echo ""
    
    # Check if there are any workspace pods for this stack
    local workspace_pods
    workspace_pods=$(kubectl get pods -n ${NAMESPACE} -l pulumi.com/stack-name=${STACK_NAME} --no-headers 2>/dev/null | wc -l)
    
    if [[ "$workspace_pods" -gt 0 ]]; then
        log_info "Found workspace pod(s) for stack. Following workspace logs..."
        kubectl logs -f -l pulumi.com/stack-name=${STACK_NAME} -n ${NAMESPACE} &
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
        kubectl logs -f deployment/pulumi-kubernetes-operator-controller-manager -n ${NAMESPACE} &
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
    log_info "Next steps:"
    echo "1. Check the AWS console to verify your resources were created"
    echo "2. Monitor the stack: kubectl get stack ${STACK_NAME} -n ${NAMESPACE}"
    echo "3. View stack outputs: kubectl get stack ${STACK_NAME} -n ${NAMESPACE} -o jsonpath='{.status.outputs}' | jq ."
    echo "4. Check workspace pods: kubectl get pods -n ${NAMESPACE} -l pulumi.com/stack-name=${STACK_NAME}"
    echo "5. Check operator logs: kubectl logs -f deployment/pulumi-kubernetes-operator-controller-manager -n ${NAMESPACE}"
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
    echo "Target namespace: $NAMESPACE"
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
    
    # Show debug info if DEBUG=1
    if [[ "${DEBUG:-0}" == "1" ]]; then
        show_debug_info
    fi
    
    check_prerequisites
    load_environment
    create_secrets
    deploy_manifests
    
    log_debug "About to monitor deployment with namespace: $NAMESPACE"
    monitor_deployment
    
    if [[ $? -eq 0 ]]; then
        display_stack_info
        validate_aws_resources
        display_next_steps
        log_success "AWS resources deployment completed successfully!"
    else
        log_error "AWS resources deployment failed!"
        log_info "Check the logs above for details. You can also run:"
        echo "  kubectl describe stack ${STACK_NAME} -n ${NAMESPACE}"
        echo "  kubectl logs deployment/pulumi-kubernetes-operator-controller-manager -n ${NAMESPACE}"
        echo "  kubectl get pods -n ${NAMESPACE} -l pulumi.com/stack-name=${STACK_NAME}"
        
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
