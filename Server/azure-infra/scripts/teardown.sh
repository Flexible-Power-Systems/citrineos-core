#!/bin/bash
# Teardown script - removes all Azure resources for CitrineOS
# WARNING: This will delete all data!
#
# Usage: ./teardown.sh [environment]
# Example: ./teardown.sh dev

set -e

ENVIRONMENT="${1:-dev}"
RESOURCE_GROUP="rg-citrine-ev-${ENVIRONMENT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}"
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║                         ⚠️  WARNING ⚠️                              ║"
echo "║     This will PERMANENTLY DELETE all resources in:                ║"
echo "║                                                                   ║"
echo "║         Resource Group: ${RESOURCE_GROUP}                         "
echo "║                                                                   ║"
echo "║     Including: PostgreSQL (ALL DATA), Container Apps, ACR,        ║"
echo "║                Key Vault, Storage, and all secrets                ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

read -p "Type 'DELETE' to confirm: " confirmation

if [[ "$confirmation" != "DELETE" ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo -e "${YELLOW}Deleting resource group: ${RESOURCE_GROUP}...${NC}"

az group delete --name "$RESOURCE_GROUP" --yes --no-wait

echo ""
echo -e "${GREEN}Resource group deletion initiated.${NC}"
echo "This runs in the background and may take 5-10 minutes to complete."
echo ""
echo "To check status: az group show --name $RESOURCE_GROUP 2>/dev/null || echo 'Deleted'"
echo ""
echo "To redeploy: ./Server/azure-infra/scripts/bootstrap.sh $ENVIRONMENT"
