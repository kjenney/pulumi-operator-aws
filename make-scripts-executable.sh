#!/bin/bash

# make-scripts-executable.sh
# Makes all scripts in the scripts directory executable

set -euo pipefail

echo "Making scripts executable..."

# Make all scripts executable
chmod +x scripts/setup-cluster.sh
chmod +x scripts/install-operator.sh
chmod +x scripts/deploy-stack.sh
chmod +x scripts/cleanup.sh
chmod +x diagnose.sh

echo "✓ All scripts are now executable!"
echo ""
echo "You can now run:"
echo "  ./diagnose.sh                  # Quick diagnostic"
echo "  ./scripts/setup-cluster.sh     # Set up cluster"
echo "  ./scripts/install-operator.sh  # Install operator" 
echo "  ./scripts/deploy-stack.sh      # Deploy AWS resources"
echo "  ./scripts/cleanup.sh           # Clean up everything"
echo ""
echo "For debugging:"
echo "  DEBUG=1 ./scripts/deploy-stack.sh"
