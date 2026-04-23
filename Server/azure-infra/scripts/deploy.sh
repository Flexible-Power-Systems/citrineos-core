#!/bin/bash
# Full deployment script for CitrineOS on Azure Container Apps
# Usage: ./deploy.sh [environment] [image-tag]
# Example: ./deploy.sh dev v1.0.0

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Configuration
ENVIRONMENT="${1:-dev}"
IMAGE_TAG="${2:-latest}"
RESOURCE_GROUP="rg-citrine-ev-${ENVIRONMENT}"

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

# Get ACR name from existing deployment
get_acr_name() {
    az acr list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null
}

# Build and push image to ACR
build_image() {
    local acr_name="$1"
    local tag="$2"
    
    log_step "Building CitrineOS image in ACR..."
    
    cd "$REPO_ROOT/Server"
    
    az acr build \
        --registry "$acr_name" \
        --image "citrineos/core:${tag}" \
        --file local.Dockerfile \
        ..
    
    log_info "Image built: ${acr_name}.azurecr.io/citrineos/core:${tag}"
}

# Update container app with new image
update_container_app() {
    local acr_name="$1"
    local tag="$2"
    
    log_step "Updating CitrineOS container app..."
    
    az containerapp update \
        --name "ca-${ENVIRONMENT}-citrineos" \
        --resource-group "$RESOURCE_GROUP" \
        --image "${acr_name}.azurecr.io/citrineos/core:${tag}"
    
    log_info "Container app updated to image: citrineos/core:${tag}"
}

# Run post-deployment configuration
run_post_deploy() {
    log_step "Running post-deployment configuration..."
    
    export RESOURCE_GROUP
    export CITRINEOS_APP="ca-${ENVIRONMENT}-citrineos"
    export HASURA_APP="ca-${ENVIRONMENT}-hasura"
    
    "$SCRIPT_DIR/post-deploy.sh"
}

# Main
main() {
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           CitrineOS Azure Deployment                      ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    log_info "Environment: $ENVIRONMENT"
    log_info "Image Tag: $IMAGE_TAG"
    log_info "Resource Group: $RESOURCE_GROUP"
    echo ""
    
    # Verify Azure CLI login
    log_step "Verifying Azure CLI login..."
    if ! az account show &>/dev/null; then
        log_error "Not logged in to Azure CLI. Run: az login"
        exit 1
    fi
    log_info "Logged in as: $(az account show --query user.name -o tsv)"
    
    # Get ACR name
    local acr_name
    acr_name=$(get_acr_name)
    if [[ -z "$acr_name" ]]; then
        log_error "No ACR found in resource group $RESOURCE_GROUP"
        log_error "Run the Bicep deployment first to create infrastructure"
        exit 1
    fi
    log_info "ACR: $acr_name"
    
    # Build image
    build_image "$acr_name" "$IMAGE_TAG"
    
    # Update container app
    update_container_app "$acr_name" "$IMAGE_TAG"
    
    # Post-deployment (wait for migrations, track tables)
    run_post_deploy
    
    echo ""
    log_step "Deployment Complete!"
    echo ""
    log_info "CitrineOS: https://ca-${ENVIRONMENT}-citrineos.$(az containerapp show --name ca-${ENVIRONMENT}-citrineos -g $RESOURCE_GROUP --query 'properties.configuration.ingress.fqdn' -o tsv | cut -d'.' -f2-)"
    log_info "Hasura Console: https://$(az containerapp show --name ca-${ENVIRONMENT}-hasura -g $RESOURCE_GROUP --query 'properties.configuration.ingress.fqdn' -o tsv)/console"
}

main "$@"
