# ArgoCD Deployment for Pulumi Operator AWS Demo

This directory contains ArgoCD Application manifests for deploying the Pulumi Kubernetes Operator and AWS resources stack using GitOps principles.

## Overview

The ArgoCD setup provides several deployment options:

1. **Individual Applications** - Deploy operator and stack separately
2. **App of Apps** - Deploy everything together with automatic discovery
3. **Ordered Deployment** - Deploy with sync waves for proper sequencing

## Prerequisites

1. **Kubernetes cluster** with ArgoCD installed
2. **Git repository** containing this code (update repository URLs in manifests)
3. **AWS credentials** configured as Kubernetes secrets
4. **Storage class** available for persistent volumes

## Quick Start

### 1. Install ArgoCD

```bash
# Run the ArgoCD installation script
./scripts/install-argocd.sh
```

This will:
- Install ArgoCD in the cluster
- Configure NodePort access
- Display admin credentials

### 2. Access ArgoCD UI

```bash
# Get the NodePort
kubectl get svc argocd-server -n argocd

# Access via browser at http://localhost:<nodeport>
# Or use port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Then access https://localhost:8080
```

### 3. Configure Git Repository

1. **Fork/clone this repository** to your Git hosting platform
2. **Update repository URLs** in the ArgoCD manifests:
   - `argocd/pulumi-stack-application.yaml`
   - `argocd/pulumi-operator-application.yaml`
   - `argocd/app-of-apps.yaml`
   - `argocd/ordered/02-pulumi-aws-stack.yaml`

3. **Configure AWS credentials** (see AWS Setup section below)

### 4. Deploy Applications

Choose one of the deployment methods:

#### Option A: App of Apps (Recommended)

```bash
# Deploy the App of Apps
kubectl apply -f argocd/app-of-apps.yaml
```

#### Option B: Ordered Deployment with Sync Waves

```bash
# Deploy ordered apps for controlled sequencing
kubectl apply -f argocd/ordered/
```

#### Option C: Individual Applications

```bash
# Deploy operator first
kubectl apply -f argocd/pulumi-operator-application.yaml

# Wait for operator to be ready, then deploy stack
kubectl apply -f argocd/pulumi-stack-application.yaml
```

## AWS Setup

### Create AWS Credentials Secret

```bash
# Create the secret with your AWS credentials
kubectl create secret generic aws-credentials \
  --from-literal=AWS_ACCESS_KEY_ID="your-access-key" \
  --from-literal=AWS_SECRET_ACCESS_KEY="your-secret-key" \
  --from-literal=AWS_REGION="us-west-2" \
  -n pulumi-aws-demo

# Or use the deployment script approach
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key" 
export AWS_REGION="us-west-2"
./scripts/deploy-stack.sh  # This will create the secret
```

### AWS IAM Permissions

Ensure your AWS credentials have permissions for:
- S3 (bucket management)
- EC2 (VPC, subnets, security groups)
- IAM (roles and policies) - if enabled

## Configuration

### Customizing Resources

Edit the `values` section in the ArgoCD Applications to control which AWS resources are created:

```yaml
resources:
  s3:
    bucket:
      enabled: true  # Create S3 bucket
    publicAccessBlock:
      enabled: true  # Block public access
  vpc:
    vpc:
      enabled: true  # Create VPC
    # ... other VPC resources
  iam:
    ec2Role:
      enabled: false  # Disable IAM resources for security
```

### Persistence Configuration

The stack uses persistent volumes for Pulumi state storage:

```yaml
pulumi:
  backend:
    persistence:
      enabled: true
      storageClass: ""  # Use default storage class
      size: "10Gi"
      annotations:
        backup.kubernetes.io/policy: "daily"  # Backup annotations
```

## Monitoring and Troubleshooting

### Check ArgoCD Application Status

```bash
# List all applications
kubectl get applications -n argocd

# Get detailed status
kubectl describe application pulumi-aws-stack -n argocd
```

### Check Pulumi Stack Status

```bash
# Check Stack resource
kubectl get stacks -n pulumi-aws-demo

# Check workspace pod logs
kubectl logs -n pulumi-aws-demo -l pulumi.com/stack-name=aws-resources

# Check operator logs
kubectl logs -n pulumi-kubernetes-operator -l app.kubernetes.io/name=pulumi-kubernetes-operator
```

### Common Issues

1. **CRDs not found**: Wait for operator to be fully deployed
2. **AWS credentials**: Verify secret exists and has correct keys
3. **Storage issues**: Check PVC status and storage class availability
4. **Sync failures**: Check ArgoCD application events and logs

## Sync Policies

### Automated Sync

Applications are configured with automated sync:
- **prune: true** - Remove resources not in Git
- **selfHeal: true** - Fix drift from desired state (disabled for stacks)
- **allowEmpty: false** - Don't sync if no resources found

### Manual Sync Control

To disable automated sync:

```bash
# Disable auto-sync for an application
kubectl patch application pulumi-aws-stack -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# Re-enable auto-sync
kubectl patch application pulumi-aws-stack -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":false}}}}'
```

## Security Considerations

1. **AWS Credentials**: Use IAM roles or external secret management when possible
2. **RBAC**: Review and customize ArgoCD RBAC policies
3. **Network Policies**: Implement network policies for production
4. **Secret Management**: Consider using External Secrets Operator or similar
5. **Backup**: Ensure Pulumi state persistence is backed up

## Production Recommendations

1. **Use specific Git tags/branches** instead of `HEAD`
2. **Enable backup for persistent volumes**
3. **Set up monitoring and alerting**
4. **Use proper IAM roles instead of static credentials**
5. **Configure resource limits and requests**
6. **Implement proper RBAC policies**
7. **Use cert-manager for webhook certificates**

## Cleanup

To remove everything:

```bash
# Delete ArgoCD applications (this will clean up managed resources)
kubectl delete -f argocd/app-of-apps.yaml

# Or delete individual applications
kubectl delete application pulumi-aws-stack pulumi-kubernetes-operator -n argocd

# The Pulumi operator will handle AWS resource cleanup automatically
# due to destroyOnFinalize: true
```

## Files Description

- `pulumi-operator-application.yaml` - ArgoCD app for Pulumi Operator
- `pulumi-stack-application.yaml` - ArgoCD app for AWS resources stack
- `app-of-apps.yaml` - App of Apps pattern for managing both
- `ordered/01-pulumi-operator.yaml` - Operator with sync wave 1
- `ordered/02-pulumi-aws-stack.yaml` - Stack with sync wave 2
- `README.md` - This documentation

## Support

For issues related to:
- **Pulumi Operator**: https://github.com/pulumi/pulumi-kubernetes-operator
- **ArgoCD**: https://argo-cd.readthedocs.io/
- **This Demo**: Check the main project repository