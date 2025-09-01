.PHONY: help cleanup deploy-app-of-apps deploy-stack install-argocd install-operator quickstart setup-cluster

help:
	@echo "Available commands:"
	@echo "  cleanup            - Clean up resources"
	@echo "  deploy-app-of-apps - Deploy ArgoCD app of apps"
	@echo "  deploy-stack       - Deploy Pulumi stack"
	@echo "  install-argocd     - Install ArgoCD"
	@echo "  install-operator   - Install Pulumi operator"
	@echo "  quickstart         - Run quickstart setup"
	@echo "  setup-cluster      - Set up Kubernetes cluster"

cleanup:
	@./scripts/cleanup.sh

deploy-app-of-apps:
	@./scripts/deploy-app-of-apps.sh

deploy-stack:
	@./scripts/deploy-stack.sh

install-argocd:
	@./scripts/install-argocd.sh

install-operator:
	@./scripts/install-operator.sh

quickstart:
	@./scripts/quickstart.sh

setup-cluster:
	@./scripts/setup-cluster.sh