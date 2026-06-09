#!/bin/bash
# Teardown script - removes all Azure resources inside a CitrineOS resource group
# WARNING: This will delete all data!
# NOTE: The resource group itself is preserved (DevOps-managed).
#
# Usage: ./teardown.sh [environment]
# Example: ./teardown.sh dev

set -e

ENVIRONMENT="${1:-dev}"
RESOURCE_GROUP="rg-citrine-os-${ENVIRONMENT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
echo "║                                                                   ║"
echo "║     The resource group itself will be preserved.                  ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

read -p "Type 'DELETE' to confirm: " confirmation

if [[ "$confirmation" != "DELETE" ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo -e "${YELLOW}Deleting all resources in: ${RESOURCE_GROUP}...${NC}"

# Get all resource IDs in the group
RESOURCE_IDS=$(az resource list --resource-group "$RESOURCE_GROUP" --query "[].id" -o tsv 2>/dev/null)

if [[ -z "$RESOURCE_IDS" ]]; then
    echo -e "${GREEN}No resources found in ${RESOURCE_GROUP}. Nothing to delete.${NC}"
    exit 0
fi

RESOURCE_COUNT=$(echo "$RESOURCE_IDS" | wc -l | tr -d ' ')
echo -e "${BLUE}Found ${RESOURCE_COUNT} resource(s) to delete.${NC}"

# Delete all resources in parallel
echo "$RESOURCE_IDS" | xargs -I{} az resource delete --ids {} --no-wait 2>/dev/null || true

echo ""
echo -e "${GREEN}Resource deletion initiated.${NC}"
echo "The resource group '${RESOURCE_GROUP}' has been preserved."
echo "Deletion may take 5-15 minutes to complete (PostgreSQL is slowest)."
echo ""
echo "To check remaining resources:"
echo "  az resource list --resource-group $RESOURCE_GROUP --query '[].{name:name, type:type}' -o table"
echo ""
echo "To redeploy: ./Server/azure-infra/scripts/bootstrap.sh $ENVIRONMENT"
