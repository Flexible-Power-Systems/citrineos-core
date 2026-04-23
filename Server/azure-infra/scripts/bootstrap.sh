#!/bin/bash
# Full infrastructure bootstrap for CitrineOS on Azure Container Apps
# This script creates everything from scratch - no clicking required!
#
# Usage: ./bootstrap.sh [environment]
# Example: ./bootstrap.sh dev

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BICEP_FILE="$SCRIPT_DIR/../container-apps-deploy.bicep"

# Configuration
ENVIRONMENT="${1:-dev}"
RESOURCE_GROUP="rg-citrine-ev-${ENVIRONMENT}"
LOCATION="${AZURE_LOCATION:-uksouth}"
IMAGE_TAG="${IMAGE_TAG:-v1.0.0}"

# Generate secure passwords if not provided
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 24)}"
HASURA_ADMIN_SECRET="${HASURA_ADMIN_SECRET:-CitrineOS!$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_step() { echo -e "\n${BLUE}==>${NC} $1"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================================
# STEP 1: Prerequisites Check
# ============================================================================
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    local missing=()
    
    command -v az &>/dev/null || missing+=("az (Azure CLI)")
    command -v jq &>/dev/null || missing+=("jq")
    command -v curl &>/dev/null || missing+=("curl")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
    
    # Check Azure login
    if ! az account show &>/dev/null; then
        log_error "Not logged in to Azure CLI. Run: az login"
        exit 1
    fi
    
    log_info "Logged in as: $(az account show --query user.name -o tsv)"
    log_info "Subscription: $(az account show --query name -o tsv)"
    
    # Check Bicep file exists
    if [[ ! -f "$BICEP_FILE" ]]; then
        log_error "Bicep file not found: $BICEP_FILE"
        exit 1
    fi
    
    log_info "All prerequisites met"
}

# ============================================================================
# STEP 2: Create Resource Group
# ============================================================================
create_resource_group() {
    log_step "Creating resource group: $RESOURCE_GROUP"
    
    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        log_warn "Resource group already exists"
    else
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
        log_info "Resource group created in $LOCATION"
    fi
}

# ============================================================================
# STEP 3: Deploy Bicep Infrastructure
# ============================================================================
deploy_infrastructure() {
    log_step "Deploying Azure infrastructure via Bicep..."
    
    log_info "This will create: PostgreSQL, Container Apps, ACR, Key Vault, Storage"
    
    local deployment_output
    deployment_output=$(az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "$BICEP_FILE" \
        --parameters \
            environmentName="$ENVIRONMENT" \
            postgresPassword="$POSTGRES_PASSWORD" \
            hasuraAdminSecret="$HASURA_ADMIN_SECRET" \
            usePlaceholderImage=true \
        --query "properties.outputs" \
        --output json 2>&1)
    
    if [[ $? -ne 0 ]]; then
        log_error "Bicep deployment failed:"
        echo "$deployment_output"
        exit 1
    fi
    
    # Extract outputs
    ACR_NAME=$(echo "$deployment_output" | jq -r '.acrName.value')
    ACR_LOGIN_SERVER=$(echo "$deployment_output" | jq -r '.acrLoginServer.value')
    HASURA_URL=$(echo "$deployment_output" | jq -r '.hasuraUrl.value')
    CITRINEOS_FQDN=$(echo "$deployment_output" | jq -r '.citrineosFqdn.value')
    POSTGRES_SERVER=$(echo "$deployment_output" | jq -r '.postgresServer.value')
    KEY_VAULT_NAME=$(echo "$deployment_output" | jq -r '.keyVaultName.value')
    
    log_info "Infrastructure deployed successfully"
    log_info "ACR: $ACR_NAME"
    log_info "PostgreSQL: $POSTGRES_SERVER"
}

# ============================================================================
# STEP 4: Create PostgreSQL Extensions
# ============================================================================
create_postgres_extensions() {
    log_step "Creating PostgreSQL extensions..."
    
    # Wait for PostgreSQL to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    sleep 30
    
    # Add firewall rule for current IP (needed for psql connection)
    local my_ip
    my_ip=$(curl -s https://api.ipify.org)
    
    log_info "Adding firewall rule for IP: $my_ip"
    az postgres flexible-server firewall-rule create \
        --resource-group "$RESOURCE_GROUP" \
        --name "psql-${ENVIRONMENT}-citrineos" \
        --rule-name "BootstrapAccess" \
        --start-ip-address "$my_ip" \
        --end-ip-address "$my_ip" \
        --output none 2>/dev/null || true
    
    # Create extensions (they're allow-listed in Bicep, but need to be created)
    log_info "Creating extensions: pgcrypto, postgis, citext"
    
    local pg_host="psql-${ENVIRONMENT}-citrineos.postgres.database.azure.com"
    
    for ext in pgcrypto postgis citext; do
        PGPASSWORD="$POSTGRES_PASSWORD" psql \
            -h "$pg_host" \
            -U citrineos_admin \
            -d citrineos \
            -c "CREATE EXTENSION IF NOT EXISTS $ext;" 2>/dev/null || {
                log_warn "Could not create $ext extension (may already exist or need retry)"
            }
    done
    
    log_info "PostgreSQL extensions configured"
}

# ============================================================================
# STEP 5: Build and Push CitrineOS Image
# ============================================================================
build_and_push_image() {
    log_step "Building CitrineOS image in Azure Container Registry..."
    
    cd "$REPO_ROOT/Server"
    
    az acr build \
        --registry "$ACR_NAME" \
        --image "citrineos/core:${IMAGE_TAG}" \
        --file local.Dockerfile \
        ..
    
    log_info "Image built: ${ACR_LOGIN_SERVER}/citrineos/core:${IMAGE_TAG}"
}

# ============================================================================
# STEP 6: Update Container App with Real Image
# ============================================================================
update_container_app() {
    log_step "Updating CitrineOS container app with real image..."
    
    local app_name="ca-${ENVIRONMENT}-citrineos"
    local image="${ACR_LOGIN_SERVER}/citrineos/core:${IMAGE_TAG}"
    
    # Get ACR credentials
    local acr_username
    local acr_password
    acr_username=$(az acr credential show --name "$ACR_NAME" --query "username" -o tsv)
    acr_password=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv)
    
    # Update container app with image and all required configuration
    az containerapp update \
        --name "$app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --image "$image" \
        --set-env-vars \
            "BOOTSTRAP_CITRINEOS_DATABASE_HOST=psql-${ENVIRONMENT}-citrineos.postgres.database.azure.com" \
            "BOOTSTRAP_CITRINEOS_DATABASE_PORT=5432" \
            "BOOTSTRAP_CITRINEOS_DATABASE_USER=citrineos_admin" \
            "BOOTSTRAP_CITRINEOS_DATABASE_NAME=citrineos" \
            "BOOTSTRAP_CITRINEOS_DATABASE_SSL_REQUIRE=true" \
            "NODE_ENV=production" \
        --output none
    
    # Set secrets
    az containerapp secret set \
        --name "$app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --secrets "db-password=$POSTGRES_PASSWORD" "acr-password=$acr_password" \
        --output none
    
    # Update env var to reference secret
    az containerapp update \
        --name "$app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --set-env-vars "BOOTSTRAP_CITRINEOS_DATABASE_PASSWORD=secretref:db-password" \
        --output none
    
    # Configure registry
    az containerapp registry set \
        --name "$app_name" \
        --resource-group "$RESOURCE_GROUP" \
        --server "$ACR_LOGIN_SERVER" \
        --username "$acr_username" \
        --password "$acr_password" \
        --output none
    
    log_info "Container app updated"
}

# ============================================================================
# STEP 7: Wait for Migrations and Configure Hasura
# ============================================================================
configure_hasura() {
    log_step "Running post-deployment configuration..."
    
    export RESOURCE_GROUP
    export CITRINEOS_APP="ca-${ENVIRONMENT}-citrineos"
    export HASURA_APP="ca-${ENVIRONMENT}-hasura"
    
    "$SCRIPT_DIR/post-deploy.sh"
}

# ============================================================================
# STEP 8: Output Summary
# ============================================================================
print_summary() {
    log_step "Deployment Complete!"
    
    local hasura_fqdn
    hasura_fqdn=$(az containerapp show --name "ca-${ENVIRONMENT}-hasura" -g "$RESOURCE_GROUP" \
        --query "properties.configuration.ingress.fqdn" -o tsv)
    
    local citrineos_fqdn
    citrineos_fqdn=$(az containerapp show --name "ca-${ENVIRONMENT}-citrineos" -g "$RESOURCE_GROUP" \
        --query "properties.configuration.ingress.fqdn" -o tsv)
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    CitrineOS Deployment Summary                   ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BLUE}Resource Group:${NC}    $RESOURCE_GROUP"
    echo -e "  ${BLUE}Location:${NC}          $LOCATION"
    echo ""
    echo -e "  ${BLUE}CitrineOS:${NC}         https://${citrineos_fqdn}"
    echo -e "  ${BLUE}OCPP WebSocket:${NC}    wss://${citrineos_fqdn}/{CHARGER_ID}"
    echo -e "  ${BLUE}Hasura Console:${NC}    https://${hasura_fqdn}/console"
    echo ""
    echo -e "  ${BLUE}Hasura Admin Secret:${NC} $HASURA_ADMIN_SECRET"
    echo ""
    echo -e "  ${YELLOW}Credentials stored in Key Vault:${NC} $KEY_VAULT_NAME"
    echo -e "    - postgres-password"
    echo -e "    - hasura-admin-secret"
    echo ""
    echo -e "  ${GREEN}To redeploy after code changes:${NC}"
    echo -e "    ./Server/azure-infra/scripts/deploy.sh $ENVIRONMENT v1.1.0"
    echo ""
    
    # Save credentials to a local file (gitignored)
    local creds_file="$REPO_ROOT/.azure-credentials-${ENVIRONMENT}"
    cat > "$creds_file" << EOF
# CitrineOS Azure Credentials - ${ENVIRONMENT}
# Generated: $(date -Iseconds)
# DO NOT COMMIT THIS FILE

RESOURCE_GROUP=$RESOURCE_GROUP
POSTGRES_SERVER=psql-${ENVIRONMENT}-citrineos.postgres.database.azure.com
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
HASURA_ADMIN_SECRET=$HASURA_ADMIN_SECRET
HASURA_URL=https://${hasura_fqdn}
CITRINEOS_URL=https://${citrineos_fqdn}
KEY_VAULT_NAME=$KEY_VAULT_NAME
ACR_NAME=$ACR_NAME
EOF
    chmod 600 "$creds_file"
    log_info "Credentials saved to: $creds_file"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║         CitrineOS Azure Bootstrap - Full Deployment               ║"
    echo "║                     No clicking required!                         ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    log_info "Environment: $ENVIRONMENT"
    log_info "Location: $LOCATION"
    echo ""
    
    check_prerequisites
    create_resource_group
    deploy_infrastructure
    create_postgres_extensions
    build_and_push_image
    update_container_app
    configure_hasura
    print_summary
}

main "$@"
