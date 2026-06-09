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
RESOURCE_GROUP="rg-citrine-os-${ENVIRONMENT}"

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

# Build and push OCPI image to ACR
build_ocpi_image() {
    local acr_name="$1"
    local tag="$2"
    
    local ocpi_dir="$REPO_ROOT/../citrineos-ocpi"
    if [[ ! -d "$ocpi_dir" ]]; then
        log_warn "citrineos-ocpi directory not found at $ocpi_dir - skipping OCPI build"
        return 0
    fi
    
    log_step "Building CitrineOS OCPI image in ACR..."
    
    cd "$ocpi_dir"
    
    az acr build \
        --registry "$acr_name" \
        --image "citrineos-ocpi:${tag}" \
        --file Server/azure.Dockerfile \
        .
    
    log_info "Image built: ${acr_name}.azurecr.io/citrineos-ocpi:${tag}"
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

# Update OCPI container app with new image
update_ocpi_container_app() {
    local acr_name="$1"
    local tag="$2"
    
    # Check if OCPI container app exists
    if ! az containerapp show --name "ca-${ENVIRONMENT}-citrineos-ocpi" -g "$RESOURCE_GROUP" &>/dev/null; then
        log_warn "OCPI container app not found - skipping update"
        return 0
    fi
    
    log_step "Updating CitrineOS OCPI container app..."
    
    az containerapp update \
        --name "ca-${ENVIRONMENT}-citrineos-ocpi" \
        --resource-group "$RESOURCE_GROUP" \
        --image "${acr_name}.azurecr.io/citrineos-ocpi:${tag}"
    
    log_info "OCPI container app updated to image: citrineos-ocpi:${tag}"
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
    
    # Build OCPI image
    build_ocpi_image "$acr_name" "$IMAGE_TAG"
    
    # Update container app
    update_container_app "$acr_name" "$IMAGE_TAG"
    
    # Update OCPI container app
    update_ocpi_container_app "$acr_name" "$IMAGE_TAG"
    
    # Post-deployment (wait for migrations, track tables)
    run_post_deploy
    
    echo ""
    log_step "Deployment Complete!"
    echo ""
    log_info "CitrineOS: https://ca-${ENVIRONMENT}-citrineos.$(az containerapp show --name ca-${ENVIRONMENT}-citrineos -g $RESOURCE_GROUP --query 'properties.configuration.ingress.fqdn' -o tsv | cut -d'.' -f2-)"
    log_info "Hasura Console: https://$(az containerapp show --name ca-${ENVIRONMENT}-hasura -g $RESOURCE_GROUP --query 'properties.configuration.ingress.fqdn' -o tsv)/console"
    log_info "OCPI: https://$(az containerapp show --name ca-${ENVIRONMENT}-citrineos-ocpi -g $RESOURCE_GROUP --query 'properties.configuration.ingress.fqdn' -o tsv 2>/dev/null || echo 'not deployed')"
    log_info "Operator UI: https://$(az containerapp show --name ca-${ENVIRONMENT}-operator-ui -g $RESOURCE_GROUP --query 'properties.configuration.ingress.fqdn' -o tsv 2>/dev/null || echo 'not deployed')"
}

main "$@"
