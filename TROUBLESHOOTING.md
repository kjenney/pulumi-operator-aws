# Troubleshooting Guide

This guide helps you troubleshoot common issues when using the Pulumi Kubernetes Operator to deploy AWS resources.

## Common Issues

### 1. Cluster Setup Issues

#### Issue: kind command not found
**Error:** `kind: command not found`

**Solution:**
```bash
# Install kind manually
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

#### Issue: Docker daemon not running
**Error:** `Cannot connect to the Docker daemon`

**Solution:**
- Start Docker Desktop (macOS/Windows)
- Start Docker daemon (Linux): `sudo systemctl start docker`

#### Issue: kubectl context not set
**Error:** `The connection to the server localhost:8080 was refused`

**Solution:**
```bash
# Set the correct context
kubectl config use-context kind-pulumi-aws-demo

# Verify
kubectl cluster-info
```

### 2. Operator Installation Issues

#### Issue: Operator pod stuck in Pending state
**Diagnosis:**
```bash
kubectl describe pod -l app.kubernetes.io/name=pulumi-kubernetes-operator -n pulumi-system
```

**Common causes:**
- Insufficient cluster resources
- Image pull errors
- Node scheduling issues

**Solution:**
```bash
# Check node resources
kubectl top nodes

# Check events
kubectl get events -n pulumi-system --sort-by='.lastTimestamp'

# Restart operator
kubectl rollout restart deployment/pulumi-kubernetes-operator -n pulumi-system
```

#### Issue: CRDs not installed
**Error:** `no matches for kind "Stack" in version "pulumi.com/v1"`

**Solution:**
```bash
# Install CRDs manually
kubectl apply -f https://raw.githubusercontent.com/pulumi/pulumi-kubernetes-operator/v1.14.0/deploy/crds/pulumi.com_stacks.yaml
```

### 3. AWS Credentials Issues

#### Issue: AWS credentials invalid
**Error:** `InvalidUserID.NotFound` or `SignatureDoesNotMatch`

**Solution:**
1. Verify credentials in `.env` file
2. Test AWS CLI access:
   ```bash
   aws sts get-caller-identity
   ```
3. Recreate secrets:
   ```bash
   kubectl delete secret aws-credentials -n pulumi-system
   ./scripts/deploy-stack.sh
   ```

#### Issue: AWS permissions insufficient
**Error:** `AccessDenied` or `UnauthorizedOperation`

**Solution:**
Ensure your AWS user/role has these permissions:
- S3: `s3:CreateBucket`, `s3:DeleteBucket`, `s3:GetBucketVersioning`, etc.
- EC2: `ec2:CreateVpc`, `ec2:DeleteVpc`, `ec2:CreateSecurityGroup`, etc.
- IAM: `iam:CreateRole`, `iam:DeleteRole`, `iam:CreatePolicy`, etc.

### 4. Pulumi Stack Issues

#### Issue: Stack stuck in "running" state
**Diagnosis:**
```bash
kubectl describe stack aws-resources -n pulumi-system
kubectl logs -f deployment/pulumi-kubernetes-operator -n pulumi-system
```

**Solution:**
```bash
# Delete and recreate the stack
kubectl delete stack aws-resources -n pulumi-system
kubectl apply -f k8s-manifests/pulumi-stack.yaml
```

#### Issue: Pulumi access token invalid
**Error:** `401 Unauthorized` from Pulumi service

**Solution:**
1. Get a new access token from [Pulumi Console](https://app.pulumi.com/account/tokens)
2. Update `.env` file
3. Recreate secret:
   ```bash
   kubectl delete secret pulumi-access-token -n pulumi-system
   ./scripts/deploy-stack.sh
   ```

#### Issue: Stack deployment fails with timeout
**Error:** `context deadline exceeded`

**Solution:**
```bash
# Increase timeout in stack spec
kubectl patch stack aws-resources -n pulumi-system --type='merge' -p='{"spec":{"retries":5}}'

# Or delete and retry
kubectl delete stack aws-resources -n pulumi-system
kubectl apply -f k8s-manifests/pulumi-stack.yaml
```

### 5. Resource Cleanup Issues

#### Issue: AWS resources not deleted
**Problem:** Resources remain after stack deletion

**Solution:**
1. Check Pulumi backend state
2. Manual cleanup via AWS Console:
   - Delete S3 buckets (empty them first)
   - Delete VPC and associated resources
   - Delete IAM roles and policies

#### Issue: Stack deletion stuck
**Problem:** `kubectl delete stack` hangs

**Solution:**
```bash
# Force delete with finalizer removal
kubectl patch stack aws-resources -n pulumi-system -p '{"metadata":{"finalizers":[]}}' --type=merge

# Then delete
kubectl delete stack aws-resources -n pulumi-system --force --grace-period=0
```

## Debugging Commands

### Check Operator Status
```bash
# Operator deployment
kubectl get deployment pulumi-kubernetes-operator -n pulumi-system

# Operator pods
kubectl get pods -l app.kubernetes.io/name=pulumi-kubernetes-operator -n pulumi-system

# Operator logs
kubectl logs -f deployment/pulumi-kubernetes-operator -n pulumi-system
```

### Check Stack Status
```bash
# Stack resource
kubectl get stack aws-resources -n pulumi-system

# Stack details
kubectl describe stack aws-resources -n pulumi-system

# Stack outputs
kubectl get stack aws-resources -n pulumi-system -o jsonpath='{.status.outputs}' | jq .
```

### Check Secrets and ConfigMaps
```bash
# List secrets
kubectl get secrets -n pulumi-system

# Check secret data (base64 encoded)
kubectl get secret aws-credentials -n pulumi-system -o yaml

# List configmaps
kubectl get configmaps -n pulumi-system

# Check configmap data
kubectl describe configmap pulumi-program -n pulumi-system
```

### Check Cluster Resources
```bash
# Node status
kubectl get nodes

# Resource usage
kubectl top nodes
kubectl top pods -n pulumi-system

# Events
kubectl get events --sort-by='.lastTimestamp' -n pulumi-system
```

## Getting Help

### Log Collection
When reporting issues, please collect these logs:

```bash
# Create a debug bundle
mkdir debug-logs
kubectl get all -n pulumi-system > debug-logs/resources.txt
kubectl describe stack aws-resources -n pulumi-system > debug-logs/stack-details.txt
kubectl logs deployment/pulumi-kubernetes-operator -n pulumi-system > debug-logs/operator-logs.txt
kubectl get events -n pulumi-system --sort-by='.lastTimestamp' > debug-logs/events.txt

# Compress and share
tar -czf debug-logs.tar.gz debug-logs/
```

### Useful Links
- [Pulumi Kubernetes Operator Documentation](https://www.pulumi.com/docs/guides/continuous-delivery/pulumi-kubernetes-operator/)
- [Pulumi AWS Provider Documentation](https://www.pulumi.com/registry/packages/aws/)
- [Kubernetes Troubleshooting Guide](https://kubernetes.io/docs/tasks/debug/)
- [AWS CLI Troubleshooting](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-troubleshooting.html)

### Community Support
- [Pulumi Community Slack](https://slack.pulumi.com/)
- [Pulumi GitHub Issues](https://github.com/pulumi/pulumi-kubernetes-operator/issues)
- [Stack Overflow](https://stackoverflow.com/questions/tagged/pulumi)

## Reset Everything

If you want to start completely fresh:

```bash
# Complete cleanup
./scripts/cleanup.sh

# Delete all docker containers and images (careful!)
docker system prune -a

# Start over
./scripts/setup-cluster.sh
./scripts/install-operator.sh
cp .env.example .env
# Edit .env with your credentials
./scripts/deploy-stack.sh
```
