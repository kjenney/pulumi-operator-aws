# Pulumi Kubernetes Operator AWS Deployment

This project demonstrates how to deploy AWS resources using the Pulumi Kubernetes Operator (PKO) v2.0+ on a local Kubernetes cluster. This project uses a **local backend** for Pulumi to eliminate external dependencies and ensure repeatability.

## Prerequisites

1. **Docker** - For running the local Kubernetes cluster
2. **kind** or **minikube** - For the local Kubernetes cluster
3. **kubectl** - Kubernetes CLI tool
4. **helm** - Package manager for Kubernetes (v3.x+)
5. **AWS CLI** - For AWS credentials configuration
6. **Pulumi CLI** - For local testing (optional)

## 🚀 Quick Start

1. Install everything by running `make quickstart`.
2. Add `127.0.0.1       argocd.localhost` to your `/etc/hosts` file.
3. Access ArgoCD at https://argocd.localhost:8443. The credentials are in `argocd-credentials.txt`.

## Optional setup

The Pulumi container image is rather large, so to speed up the loading of stack resources it has beem saved locally. The image is loaded into the Kubernetes cluster on creation if a specific files exists. The file name is `pulumi-image.tar`. Use `docker save pulumi/pulumi:latest-nonroot -o pulumi-image.tar` to create the file. 

### Installation

1. **Clone and navigate to the project:**
   ```bash
   cd pulumi-operator-aws
   ```

2. **Set up environment variables:**
   ```bash
   cp .env.example .env
   # Edit .env with your AWS credentials (no Pulumi token needed for local backend)
   ```

3. **Create your Kubernetes cluster and install Pulumi Operator:**
   ```bash
   make setup-cluster
   make install-argocd
   make deploy-app-of-apps
   ```

5. **Monitor the deployment:**
   ```bash
   # Check the stack status
   kubectl get stack -A
   
   # View logs
   # Get the stack namespace from .env
   kubectl logs -l auto.pulumi.com/component=workspace -n ${STACK-NAMESPAC} <-- replace namespace
   ```

### Helm Chart Configuration

The Helm chart can be configured in two ways:

#### Option 1: Using .env File (Recommended)

The deployment script automatically reads from `.env` file. See `.env.example` for the format.

#### Option 2: Using values.yaml File

```yaml
# Example customization
global:
  namespace:
    name: my-pulumi-demo
    
aws:
  region: us-east-1
  
project:
  name: my-awesome-project
  environment: production
  bucketName: my-awesome-project-prod-bucket
  tags:
    Team: platform
    Environment: production
    CostCenter: "12345"
```

See [`helm-chart/README.md`](helm-chart/README.md) for complete configuration options.

## 📋 AWS Resources Deployed

Both deployment methods create the following AWS resources:

- **S3 Bucket**: Versioned and encrypted storage bucket
- **VPC**: Virtual Private Cloud with DNS support
- **Internet Gateway**: For public internet access
- **Public Subnet**: Subnet with automatic public IP assignment
- **Route Table**: Routing configuration for public subnet
- **Security Group**: Web security group (HTTP, HTTPS, SSH access)
- **IAM Role**: EC2 instance role with S3 access
- **IAM Policy**: Custom policy for S3 bucket access
- **Instance Profile**: IAM instance profile for EC2 instances

## ⚙️ Configuration Options

### Namespace Configuration

The deployment supports flexible namespace configuration through environment variables:

- **OPERATOR_NAMESPACE**: Where the Pulumi Kubernetes Operator is deployed (default: `pulumi-system`)
- **STACK_NAMESPACE**: Where Pulumi Stacks are deployed (default: `pulumi-aws-demo`)

This separation provides:
- **Security isolation**: Stack resources are isolated in their own namespace
- **Multi-tenancy**: Different teams can have their own stack namespaces
- **Clear separation**: Infrastructure (operator) vs applications (stacks)
- **Fine-grained RBAC**: Permissions can be controlled per namespace

### Resource Configuration

Customize the deployment by modifying:
- **Helm Chart**: Edit `helm-chart/values.yaml` for Helm deployments

## 📊 Monitoring and Troubleshooting

### Health Checks

```bash
# Check stack status
kubectl get stack -A
kubectl describe stack aws-resources -n pulumi-aws-demo

# View logs
kubectl logs -l pulumi.com/stack=aws-resources -n pulumi-aws-demo
kubectl logs -l app.kubernetes.io/name=pulumi-kubernetes-operator -n pulumi-system
```

### Common Issues

**Stack Stalled with "SourceUnavailable":**
- The stack is resolved by using local backend configuration with proper workspace setup
- Fixed automatically in the current Helm chart templates

**npm Permission Errors:**
- Resolved by init container that copies program files to writable workspace
- The workspace uses separate volumes for program files and npm dependencies

See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for detailed troubleshooting guide.

## 🧹 Cleanup

```bash
# Use the cleanup script
./scripts/cleanup.sh
```

## 🏗️ Architecture

### Helm Chart Architecture
```
┌─────────────────────────────────┐
│         Helm Chart              │
│  ┌─────────────┐ ┌────────────┐ │
│  │   Values    │ │ Templates  │ │
│  │    .yaml    │ │   .yaml    │ │
│  └─────────────┘ └────────────┘ │
└─────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│     Kubernetes Resources        │
│  ┌──────────┐  ┌──────────────┐ │
│  │Namespace │  │ServiceAccount│ │
│  │Secrets   │  │RBAC          │ │
│  │ConfigMap │  │Stack         │ │
│  └──────────┘  └──────────────┘ │
└─────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│    Pulumi Kubernetes Operator   │
│         (pulumi-system)         │
└─────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│         AWS Resources           │
│   S3 • VPC • IAM • Security    │
└─────────────────────────────────┘
```

## 🔐 Security Notes

- AWS credentials are stored as Kubernetes secrets and automatically base64 encoded
- Ensure proper RBAC permissions are configured
- Use least-privilege AWS IAM policies
- Consider using AWS IAM roles for service accounts (IRSA) in production
- Regularly rotate access keys and tokens
- Review security group rules for production deployments

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with both deployment methods
5. Submit a pull request

## 📚 References

- [Pulumi Kubernetes Operator Documentation](https://www.pulumi.com/docs/guides/continuous-delivery/pulumi-kubernetes-operator/)
- [Pulumi AWS Provider Documentation](https://www.pulumi.com/registry/packages/aws/)
- [Helm Documentation](https://helm.sh/docs/)
- [Kind Documentation](https://kind.sigs.k8s.io/)

## 📄 License

This project is licensed under the MIT License.
