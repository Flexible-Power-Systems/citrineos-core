#!/bin/bash
# Deploy EVerest OCPP 2.0.1 Charger Emulator to Azure Container Instances
# 
# Prerequisites:
#   - Azure CLI logged in
#   - Existing CitrineOS deployment on Azure

set -e

# Default values
ENVIRONMENT="${1:-dev}"
RESOURCE_GROUP="rg-citrine-os-${ENVIRONMENT}"
LOCATION="uksouth"
EVEREST_IMAGE_TAG="0.0.23"

# Get CitrineOS URL from existing deployment
echo "=== Fetching CitrineOS endpoint ==="
CITRINEOS_FQDN=$(az containerapp show --name "ca-${ENVIRONMENT}-citrineos" -g "$RESOURCE_GROUP" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null || echo "")

if [ -z "$CITRINEOS_FQDN" ]; then
    echo "Error: Could not find CitrineOS deployment in $RESOURCE_GROUP"
    echo "Please ensure CitrineOS is deployed first."
    exit 1
fi

# Use cp001 as default charger ID
CITRINEOS_URL="wss://${CITRINEOS_FQDN}/cp001"
echo "CitrineOS URL: $CITRINEOS_URL"

# Deploy EVerest emulator
echo ""
echo "=== Deploying EVerest Emulator ==="
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "${SCRIPT_DIR}/../everest-emulator.bicep" \
    --parameters \
        environmentName="$ENVIRONMENT" \
        location="$LOCATION" \
        everestImageTag="$EVEREST_IMAGE_TAG" \
        citrineosCsmsUrl="$CITRINEOS_URL" \
    --query "properties.outputs" \
    -o json

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Get emulator details:"
echo "  az container show -n aci-${ENVIRONMENT}-everest-emulator -g $RESOURCE_GROUP --query '{fqdn:ipAddress.fqdn, state:instanceView.state}' -o json"
echo ""
echo "View logs:"
echo "  az container logs -n aci-${ENVIRONMENT}-everest-emulator -g $RESOURCE_GROUP --container-name manager --follow"
echo ""
