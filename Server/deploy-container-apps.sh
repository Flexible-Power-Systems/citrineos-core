#!/bin/bash
# Deploy CitrineOS to Azure Container Apps
# Usage: ./deploy-container-apps.sh <resource-group-name> [existing-postgres-server]

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 CitrineOS Azure Container Apps Deployment${NC}"
echo "================================================="

# Check arguments
if [ -z "$1" ]; then
  echo -e "${RED}Error: Resource group name required${NC}"
  echo "Usage: ./deploy-container-apps.sh <resource-group-name> [existing-postgres-server]"
  exit 1
fi

RESOURCE_GROUP=$1
EXISTING_POSTGRES=${2:-}
ENVIRONMENT="dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if logged in to Azure
if ! az account show &> /dev/null; then
  echo -e "${YELLOW}Not logged in to Azure. Logging in...${NC}"
  az login
fi

# Get current subscription and location
SUBSCRIPTION=$(az account show --query name -o tsv)
echo -e "${GREEN}✓ Using subscription: ${SUBSCRIPTION}${NC}"

# Get resource group location (or default to uksouth)
if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
  LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
  echo -e "${GREEN}✓ Resource group exists in ${LOCATION}${NC}"
else
  LOCATION="uksouth"
  echo -e "${YELLOW}Resource group '$RESOURCE_GROUP' doesn't exist. Creating in ${LOCATION}...${NC}"
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
fi

# Generate secure passwords
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
HASURA_SECRET="CitrineOS!$(openssl rand -base64 12 | tr -d '/+=')"

echo ""
echo -e "${BLUE}📝 Deployment Parameters:${NC}"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Environment: $ENVIRONMENT"
echo "  Location: $LOCATION"
echo "  Template: Container Apps (recommended)"
if [ -n "$EXISTING_POSTGRES" ]; then
  echo "  Existing PostgreSQL: $EXISTING_POSTGRES"
else
  echo "  PostgreSQL: Will create new"
fi

echo ""
echo -e "${YELLOW}Container Apps Benefits:${NC}"
echo "  ✓ Built-in HTTPS/TLS termination"
echo "  ✓ WebSocket support for OCPP"
echo "  ✓ Auto-scaling"
echo "  ✓ Separate quota from ACI"
echo ""

read -p "Continue with deployment? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Deployment cancelled"
  exit 0
fi

# Step 1: Deploy infrastructure with placeholder image
echo ""
echo -e "${GREEN}Step 1: Deploying Azure Container Apps infrastructure...${NC}"
echo "  (This may take 5-10 minutes for PostgreSQL + Container Apps Environment)"
echo "  Using placeholder image initially - will update after building CitrineOS"

DEPLOYMENT_NAME="citrineos-ca-$(date +%Y%m%d-%H%M%S)"

if [ -n "$EXISTING_POSTGRES" ]; then
  az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$SCRIPT_DIR/azure-infra/container-apps-deploy.bicep" \
    --parameters \
      environmentName="$ENVIRONMENT" \
      existingPostgresServer="$EXISTING_POSTGRES" \
      postgresPassword="$POSTGRES_PASSWORD" \
      hasuraAdminSecret="$HASURA_SECRET" \
      usePlaceholderImage=true
else
  az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$SCRIPT_DIR/azure-infra/container-apps-deploy.bicep" \
    --parameters \
      environmentName="$ENVIRONMENT" \
      postgresPassword="$POSTGRES_PASSWORD" \
      hasuraAdminSecret="$HASURA_SECRET" \
      usePlaceholderImage=true
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
echo -e "${GREEN}Step 3: Building and pushing CitrineOS container to ACR...${NC}"
echo "  (Building in Azure - no local Docker required)"

# Login to ACR
az acr login --name "$ACR_NAME"

# Build and push using ACR Build
az acr build \
  --registry "$ACR_NAME" \
  --image citrineos/core:v1.0.0 \
  --file "$SCRIPT_DIR/local.Dockerfile" \
  "$SCRIPT_DIR/.."

echo -e "${GREEN}✓ Image built and pushed to ACR${NC}"

# Step 4: Update container app with actual CitrineOS image and configuration
echo ""
echo -e "${GREEN}Step 4: Updating CitrineOS container app with full configuration...${NC}"
echo "  (Redeploying with ACR image and environment variables)"

# Get PostgreSQL server name
POSTGRES_SERVER=$(az deployment group show \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.outputs.postgresServer.value -o tsv 2>/dev/null || echo "psql-${ENVIRONMENT}-citrineos.postgres.database.azure.com")

# Get storage account name
STORAGE_ACCOUNT=$(az deployment group show \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.outputs.storageAccountName.value -o tsv 2>/dev/null || az storage account list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv)

# Get ACR password
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query passwords[0].value -o tsv)

# Get storage connection string
STORAGE_CONNECTION=$(az storage account show-connection-string --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query connectionString -o tsv)

# Update container app with secrets, registry, and image
az containerapp update \
  --name "ca-${ENVIRONMENT}-citrineos" \
  --resource-group "$RESOURCE_GROUP" \
  --set-env-vars \
    "DB_HOST=$POSTGRES_SERVER" \
    "DB_PORT=5432" \
    "DB_USER=citrineos_admin" \
    "DB_NAME=citrineos" \
    "NODE_ENV=production"

# Set secrets
az containerapp secret set \
  --name "ca-${ENVIRONMENT}-citrineos" \
  --resource-group "$RESOURCE_GROUP" \
  --secrets \
    "db-password=$POSTGRES_PASSWORD" \
    "storage-connection=$STORAGE_CONNECTION" \
    "acr-password=$ACR_PASSWORD"

# Configure registry and update image
az containerapp registry set \
  --name "ca-${ENVIRONMENT}-citrineos" \
  --resource-group "$RESOURCE_GROUP" \
  --server "$ACR_LOGIN_SERVER" \
  --username "$ACR_NAME" \
  --password "$ACR_PASSWORD"

# Update with secret-based env vars and final image
az containerapp update \
  --name "ca-${ENVIRONMENT}-citrineos" \
  --resource-group "$RESOURCE_GROUP" \
  --image "${ACR_LOGIN_SERVER}/citrineos/core:v1.0.0" \
  --set-env-vars \
    "DB_PASSWORD=secretref:db-password" \
    "STORAGE_CONNECTION_STRING=secretref:storage-connection"

echo -e "${GREEN}✓ Container app updated with full configuration${NC}"

# Save connection info
echo ""
echo -e "${GREEN}💾 Saving deployment details...${NC}"

cat > "$SCRIPT_DIR/azure-deployment-info.txt" <<EOF
CitrineOS Azure Container Apps Deployment
==========================================
Generated: $(date)

Resource Group: $RESOURCE_GROUP
Environment: $ENVIRONMENT
Deployment Name: $DEPLOYMENT_NAME

ENDPOINTS:
----------
Hasura Console: $HASURA_URL/console
Hasura Admin Secret: $HASURA_SECRET

OCPP Endpoints (Secure WebSocket - use wss://):
- OCPP: wss://${CITRINEOS_FQDN}/YOUR_CHARGER_ID

Note: Container Apps provides automatic HTTPS/TLS.
Your chargers should connect using wss:// (secure WebSocket).

AZURE RESOURCES:
----------------
Container Registry: $ACR_LOGIN_SERVER
CitrineOS FQDN: $CITRINEOS_FQDN

DATABASE:
---------
PostgreSQL Password: $POSTGRES_PASSWORD
(Also stored securely in Container App secrets)

USEFUL COMMANDS:
----------------
# View CitrineOS logs
az containerapp logs show --name ca-${ENVIRONMENT}-citrineos --resource-group $RESOURCE_GROUP --follow

# View Hasura logs  
az containerapp logs show --name ca-${ENVIRONMENT}-hasura --resource-group $RESOURCE_GROUP --follow

# Scale CitrineOS
az containerapp update --name ca-${ENVIRONMENT}-citrineos --resource-group $RESOURCE_GROUP --min-replicas 1 --max-replicas 5

# Rebuild and redeploy CitrineOS
az acr build --registry $ACR_NAME --image citrineos/core:v1.0.1 --file local.Dockerfile ..
az containerapp update --name ca-${ENVIRONMENT}-citrineos --resource-group $RESOURCE_GROUP --image ${ACR_LOGIN_SERVER}/citrineos/core:v1.0.1
EOF

echo -e "${GREEN}✓ Deployment info saved to azure-deployment-info.txt${NC}"

# Summary
echo ""
echo "========================================"
echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo "========================================"
echo ""
echo -e "${BLUE}Hasura Console:${NC}"
echo "  URL: $HASURA_URL/console"
echo "  Secret: $HASURA_SECRET"
echo ""
echo -e "${BLUE}OCPP WebSocket Endpoint:${NC}"
echo "  wss://${CITRINEOS_FQDN}/YOUR_CHARGER_ID"
echo ""
echo -e "${BLUE}Configure your EV Charger:${NC}"
echo "  Protocol: OCPP 1.6 or 2.0.1"
echo "  WebSocket URL: wss://${CITRINEOS_FQDN}/AE5044L1GR1C00007W"
echo "  (Replace with your actual charger ID)"
echo ""
echo -e "${YELLOW}⚠️  Important: Use wss:// (secure WebSocket)${NC}"
echo "  Container Apps provides automatic TLS certificates."
echo ""
