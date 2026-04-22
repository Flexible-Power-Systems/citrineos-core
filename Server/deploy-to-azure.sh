#!/bin/bash
# Quick Deploy Script for CitrineOS to Azure
# Usage: ./deploy-to-azure.sh <resource-group-name> [existing-postgres-server]

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 CitrineOS Quick Deploy to Azure${NC}"
echo "========================================"

# Check arguments
if [ -z "$1" ]; then
  echo -e "${RED}Error: Resource group name required${NC}"
  echo "Usage: ./deploy-to-azure.sh <resource-group-name> [existing-postgres-server]"
  exit 1
fi

RESOURCE_GROUP=$1
EXISTING_POSTGRES=${2:-}
ENVIRONMENT="dev"
LOCATION="eastus"

# Check if logged in to Azure
if ! az account show &> /dev/null; then
  echo -e "${YELLOW}Not logged in to Azure. Logging in...${NC}"
  az login
fi

# Get current subscription
SUBSCRIPTION=$(az account show --query name -o tsv)
echo -e "${GREEN}✓ Using subscription: ${SUBSCRIPTION}${NC}"

# Check if resource group exists
if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
  echo -e "${YELLOW}Resource group '$RESOURCE_GROUP' doesn't exist. Creating...${NC}"
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
else
  echo -e "${GREEN}✓ Resource group exists${NC}"
fi

# Generate secure passwords
POSTGRES_PASSWORD=$(openssl rand -base64 24)
HASURA_SECRET="CitrineOS!$(openssl rand -base64 12)"

echo ""
echo -e "${YELLOW}📝 Deployment Parameters:${NC}"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Environment: $ENVIRONMENT"
echo "  Location: $LOCATION"
if [ -n "$EXISTING_POSTGRES" ]; then
  echo "  Existing PostgreSQL: $EXISTING_POSTGRES"
else
  echo "  PostgreSQL: Will create new"
fi

echo ""
read -p "Continue with deployment? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Deployment cancelled"
  exit 0
fi

# Step 1: Deploy infrastructure
echo ""
echo -e "${GREEN}Step 1: Deploying Azure infrastructure...${NC}"

DEPLOYMENT_NAME="citrineos-$(date +%Y%m%d-%H%M%S)"

if [ -n "$EXISTING_POSTGRES" ]; then
  az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file azure-infra/quick-deploy.bicep \
    --parameters \
      environmentName="$ENVIRONMENT" \
      existingPostgresServer="$EXISTING_POSTGRES" \
      postgresPassword="$POSTGRES_PASSWORD" \
      hasuraAdminSecret="$HASURA_SECRET"
else
  az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file azure-infra/quick-deploy.bicep \
    --parameters \
      environmentName="$ENVIRONMENT" \
      postgresPassword="$POSTGRES_PASSWORD" \
      hasuraAdminSecret="$HASURA_SECRET"
fi

echo -e "${GREEN}✓ Infrastructure deployed${NC}"

# Get deployment outputs
echo ""
echo -e "${GREEN}Step 2: Getting deployment outputs...${NC}"

ACR_NAME=$(az deployment group show \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.outputs.acrName.value -o tsv)

ACR_LOGIN_SERVER=$(az deployment group show \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.outputs.acrLoginServer.value -o tsv)

HASURA_URL=$(az deployment group show \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.outputs.hasuraUrl.value -o tsv)

CITRINEOS_FQDN=$(az deployment group show \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.outputs.citrineosFqdn.value -o tsv)

echo -e "${GREEN}✓ Got deployment outputs${NC}"

# Step 3: Build and push CitrineOS image
echo ""
echo -e "${GREEN}Step 3: Building and pushing CitrineOS container...${NC}"

# Login to ACR
az acr login --name "$ACR_NAME"

# Build and push using ACR Build (no local docker required!)
az acr build \
  --registry "$ACR_NAME" \
  --image citrineos/core:v1.0.0 \
  --file local.Dockerfile \
  .

echo -e "${GREEN}✓ Image built and pushed to ACR${NC}"

# Step 4: Update container to use new image
echo ""
echo -e "${GREEN}Step 4: Updating CitrineOS container with ACR image...${NC}"

# Enable admin access for container instances to pull from ACR
ACR_USERNAME=$(az acr credential show --name "$ACR_NAME" --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query passwords[0].value -o tsv)

# Update the container (re-deploy with new image)
az container create \
  --resource-group "$RESOURCE_GROUP" \
  --name "aci-${ENVIRONMENT}-citrineos" \
  --image "${ACR_LOGIN_SERVER}/citrineos/core:v1.0.0" \
  --cpu 2 \
  --memory 4 \
  --ports 8081 8082 8092 \
  --dns-name-label "${ENVIRONMENT}-citrineos-$(echo $RESOURCE_GROUP | md5sum | cut -c1-8)" \
  --registry-login-server "$ACR_LOGIN_SERVER" \
  --registry-username "$ACR_USERNAME" \
  --registry-password "$ACR_PASSWORD" \
  --restart-policy Always

echo -e "${GREEN}✓ Container updated${NC}"

# Save connection info
echo ""
echo -e "${GREEN}💾 Saving connection details...${NC}"

cat > azure-deployment-info.txt <<EOF
CitrineOS Azure Deployment Info
Generated: $(date)
================================

Resource Group: $RESOURCE_GROUP
Environment: $ENVIRONMENT
Deployment Name: $DEPLOYMENT_NAME

ENDPOINTS:
----------
Hasura Console: $HASURA_URL/console
Hasura Admin Secret: $HASURA_SECRET

OCPP Endpoints:
- OCPP 1.6:        ws://${CITRINEOS_FQDN}:8092/YOUR_CHARGER_ID
- OCPP 2.0.1 SP0:  ws://${CITRINEOS_FQDN}:8081/YOUR_CHARGER_ID
- OCPP 2.0.1 SP1:  ws://${CITRINEOS_FQDN}:8082/YOUR_CHARGER_ID

AZURE RESOURCES:
----------------
Container Registry: $ACR_LOGIN_SERVER
CitrineOS FQDN: $CITRINEOS_FQDN

DATABASE:
---------
Connection saved in Key Vault (check Azure Portal)
Admin Password: $POSTGRES_PASSWORD

USEFUL COMMANDS:
----------------
# View logs
az container logs --resource-group $RESOURCE_GROUP --name aci-${ENVIRONMENT}-citrineos --follow

# Restart container
az container restart --resource-group $RESOURCE_GROUP --name aci-${ENVIRONMENT}-citrineos

# Check status
az container show --resource-group $RESOURCE_GROUP --name aci-${ENVIRONMENT}-citrineos --query instanceView.state

# Connect to PostgreSQL
psql "postgresql://citrineos_admin:$POSTGRES_PASSWORD@$(az deployment group show --name $DEPLOYMENT_NAME --resource-group $RESOURCE_GROUP --query properties.outputs.postgresServer.value -o tsv):5432/citrineos?sslmode=require"

EOF

echo -e "${GREEN}✓ Connection details saved to: azure-deployment-info.txt${NC}"

# Final output
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Your charger endpoint (OCPP 1.6):"
echo -e "${YELLOW}ws://${CITRINEOS_FQDN}:8092/AE5044L1GR1C00007W${NC}"
echo ""
echo "View logs:"
echo "  az container logs --resource-group $RESOURCE_GROUP --name aci-${ENVIRONMENT}-citrineos --follow"
echo ""
echo "All connection details saved in: azure-deployment-info.txt"
echo ""
