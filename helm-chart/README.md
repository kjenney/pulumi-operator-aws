# Pulumi Operator AWS Helm Chart

This Helm chart deploys AWS resources using the Pulumi Kubernetes Operator. It combines the Kubernetes manifests and Pulumi program into a single, configurable Helm chart.

## Prerequisites

- Kubernetes cluster with the Pulumi Kubernetes Operator installed
- AWS credentials with appropriate permissions
- Pulumi access token
- Helm 3.x

## Installation

1. **Install the Pulumi Kubernetes Operator** (if not already installed):
   ```bash
   kubectl apply -f https://github.com/pulumi/pulumi-kubernetes-operator/releases/download/v1.15.0/deploy.yaml
   ```

2. **Configure your values** by copying and editing the values file:
   ```bash
   cp helm-chart/values.yaml my-values.yaml
   # Edit my-values.yaml with your specific configuration
   ```

3. **Set up secrets** (you'll need to base64 encode these values):
   ```bash
   # Set AWS credentials in values.yaml
   aws:
     credentials:
       accessKeyId: "<base64-encoded-access-key>"
       secretAccessKey: "<base64-encoded-secret-key>"
   
   # Set Pulumi access token in values.yaml  
   pulumi:
     accessToken:
       token: "<base64-encoded-token>"
   ```

4. **Install the chart**:
   ```bash
   helm install pulumi-aws-demo ./helm-chart -f my-values.yaml
   ```

## Configuration

The following table lists the configurable parameters and their default values:

### Global Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `global.namespace.name` | Kubernetes namespace name | `pulumi-aws-demo` |
| `global.namespace.create` | Create the namespace | `true` |

### AWS Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `aws.region` | AWS region | `us-west-2` |
| `aws.credentials.secretName` | Secret name for AWS credentials | `aws-credentials` |

### Pulumi Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `pulumi.project.name` | Pulumi project name | `aws-resources` |
| `pulumi.stack.name` | Pulumi stack name | `aws-resources` |
| `pulumi.stack.environment` | Environment name | `dev` |
| `pulumi.stack.destroyOnFinalize` | Clean up resources on deletion | `true` |
| `pulumi.stack.resyncFrequencySeconds` | Stack refresh frequency | `60` |

### Project Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `project.name` | Project name | `pulumi-aws-demo` |
| `project.environment` | Environment | `dev` |
| `project.bucketName` | S3 bucket name | `pulumi-aws-demo-bucket` |

## AWS Resources Created

This Helm chart will create the following AWS resources:

- **S3 Bucket**: Versioned and encrypted bucket for storage
- **VPC**: Virtual Private Cloud with DNS support
- **Internet Gateway**: For public internet access  
- **Public Subnet**: Subnet with public IP assignment
- **Route Table**: Routing table for public subnet
- **Security Group**: Web security group (HTTP, HTTPS, SSH)
- **IAM Role**: EC2 instance role
- **IAM Policy**: S3 access policy
- **Instance Profile**: For EC2 instances

## Usage Examples

### Basic Installation

```bash
helm install my-pulumi-stack ./helm-chart
```

### Custom Configuration

```bash
helm install my-pulumi-stack ./helm-chart \
  --set global.namespace.name=my-namespace \
  --set aws.region=us-east-1 \
  --set project.environment=prod
```

### Using Custom Values File

```yaml
# custom-values.yaml
global:
  namespace:
    name: production-pulumi
    
aws:
  region: us-east-1
  credentials:
    accessKeyId: "QUtJQUk..."  # base64 encoded
    secretAccessKey: "V1NTRUtyZXQ..."  # base64 encoded

project:
  name: production-app
  environment: prod
  bucketName: production-app-prod-bucket
  tags:
    Environment: prod
    Team: platform
    CostCenter: "12345"

pulumi:
  stack:
    resyncFrequencySeconds: 300  # 5 minutes
```

```bash
helm install production-stack ./helm-chart -f custom-values.yaml
```

## Monitoring and Troubleshooting

### Check Stack Status
```bash
kubectl get stack -n pulumi-aws-demo
kubectl describe stack aws-resources -n pulumi-aws-demo
```

### View Logs
```bash
# Stack execution logs
kubectl logs -l pulumi.com/stack=aws-resources -n pulumi-aws-demo

# Operator logs
kubectl logs -l app.kubernetes.io/name=pulumi-kubernetes-operator -n pulumi-system
```

### Common Issues

1. **Stack stuck in pending**: Check operator logs and ensure secrets are properly configured
2. **AWS permission errors**: Verify IAM permissions for the provided credentials
3. **Resource conflicts**: Ensure bucket names and other resources don't conflict

## Uninstallation

```bash
helm uninstall my-pulumi-stack
```

This will trigger the `destroyOnFinalize` flag and automatically clean up all AWS resources.

## Development

To modify the Pulumi program, edit the TypeScript code in `templates/_helpers.tpl` under the `pulumi-operator-aws.pulumi-program` template.

## Security Considerations

- Store sensitive values (AWS keys, Pulumi tokens) in Kubernetes secrets
- Use least-privilege IAM policies
- Consider using AWS IAM roles for service accounts (IRSA) instead of static credentials
- Restrict security group rules to specific IP ranges in production

## License

This chart is provided under the same license as the Pulumi Kubernetes Operator.
