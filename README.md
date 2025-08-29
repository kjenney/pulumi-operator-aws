# Pulumi Kubernetes Operator AWS Deployment

This project demonstrates how to deploy AWS resources using the Pulumi Kubernetes Operator (PKO) v2.0+ on a local Kubernetes cluster.

## Prerequisites

1. **Docker** - For running the local Kubernetes cluster
2. **kind** or **minikube** - For the local Kubernetes cluster
3. **kubectl** - Kubernetes CLI tool
4. **helm** - Package manager for Kubernetes
5. **AWS CLI** - For AWS credentials configuration
6. **Pulumi CLI** - For local testing (optional)

## Quick Start

1. **Clone and navigate to the project:**
   ```bash
   cd pulumi-operator-aws
   ```

2. **Set up environment variables:**
   ```bash
   cp .env.example .env
   # Edit .env with your AWS credentials and configuration
   ```

3. **Create and configure the local Kubernetes cluster:**
   ```bash
   ./scripts/setup-cluster.sh
   ```

4. **Install the Pulumi Kubernetes Operator:**
   ```bash
   ./scripts/install-operator.sh
   ```

5. **Deploy the AWS resources:**
   ```bash
   ./scripts/deploy-stack.sh
   ```

6. **Monitor the deployment:**
   ```bash
   kubectl get stacks -n pulumi-system
   kubectl logs -f deployment/pulumi-kubernetes-operator -n pulumi-system
   ```

## AWS Resources Deployed

This example deploys the following AWS resources:
- S3 Bucket with versioning enabled
- EC2 Security Group with HTTP/HTTPS rules
- IAM Role and Policy for EC2 instances

## Configuration

The deployment can be customized by modifying:
- `pulumi-program/Pulumi.dev.yaml` - Stack configuration values
- `pulumi-program/index.ts` - AWS resources definition
- `k8s-manifests/pulumi-stack.yaml` - Kubernetes deployment configuration

## Monitoring and Troubleshooting

See `TROUBLESHOOTING.md`.

## Cleanup

To clean up all resources:
```bash
./scripts/cleanup.sh
```

## Security Notes

- AWS credentials are stored as Kubernetes secrets
- Ensure proper RBAC permissions are configured
- Use least-privilege AWS IAM policies
- Consider using AWS IAM roles for service accounts (IRSA) in production

## References

- [Pulumi Kubernetes Operator Documentation](https://www.pulumi.com/docs/guides/continuous-delivery/pulumi-kubernetes-operator/)
- [Pulumi AWS Provider Documentation](https://www.pulumi.com/registry/packages/aws/)
- [Kind Documentation](https://kind.sigs.k8s.io/)
