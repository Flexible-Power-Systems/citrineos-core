#!/bin/bash
# Post-deployment script for CitrineOS on Azure Container Apps
# Automatically tracks all PostgreSQL tables in Hasura GraphQL

set -e

# Configuration (can be overridden via environment variables)
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-citrine-ev-dev}"
CITRINEOS_APP="${CITRINEOS_APP:-ca-dev-citrineos}"
HASURA_APP="${HASURA_APP:-ca-dev-hasura}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-300}"  # 5 minutes max wait for migrations

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get Hasura endpoint
get_hasura_endpoint() {
    local fqdn
    fqdn=$(az containerapp show --name "$HASURA_APP" -g "$RESOURCE_GROUP" \
        --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null)
    
    if [[ -z "$fqdn" ]]; then
        log_error "Failed to get Hasura endpoint"
        exit 1
    fi
    
    echo "https://$fqdn"
}

# Get Hasura admin secret from container app secrets
get_hasura_secret() {
    az containerapp secret show --name "$HASURA_APP" -g "$RESOURCE_GROUP" \
        --secret-name admin-secret --query "value" -o tsv 2>/dev/null
}

# Wait for CitrineOS migrations to complete
wait_for_migrations() {
    log_info "Waiting for CitrineOS migrations to complete..."
    
    local elapsed=0
    local interval=10
    
    while [[ $elapsed -lt $MAX_WAIT_SECONDS ]]; do
        # Check logs for migration completion
        local logs
        logs=$(az containerapp logs show --name "$CITRINEOS_APP" -g "$RESOURCE_GROUP" \
            --tail 50 2>/dev/null | grep -i "migration completed successfully" || true)
        
        if [[ -n "$logs" ]]; then
            log_info "Migrations completed successfully!"
            return 0
        fi
        
        # Also check if server is listening (migrations are done)
        logs=$(az containerapp logs show --name "$CITRINEOS_APP" -g "$RESOURCE_GROUP" \
            --tail 20 2>/dev/null | grep -iE "server.*listening|started.*8080" || true)
        
        if [[ -n "$logs" ]]; then
            log_info "CitrineOS server is running - migrations complete"
            return 0
        fi
        
        # Check for errors
        local errors
        errors=$(az containerapp logs show --name "$CITRINEOS_APP" -g "$RESOURCE_GROUP" \
            --tail 20 2>/dev/null | grep -i "app crashed" || true)
        
        if [[ -n "$errors" ]]; then
            log_error "CitrineOS crashed during startup. Check logs:"
            log_error "  az containerapp logs show --name $CITRINEOS_APP -g $RESOURCE_GROUP --tail 50"
            exit 1
        fi
        
        log_info "Waiting for migrations... (${elapsed}s / ${MAX_WAIT_SECONDS}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout waiting for migrations after ${MAX_WAIT_SECONDS}s"
    exit 1
}

# Wait for Hasura to be healthy
wait_for_hasura() {
    log_info "Waiting for Hasura to be ready..."
    
    local endpoint="$1"
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        local status
        status=$(curl -s -o /dev/null -w "%{http_code}" "${endpoint}/healthz" 2>/dev/null || echo "000")
        
        if [[ "$status" == "200" ]]; then
            log_info "Hasura is healthy!"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log_info "Hasura not ready (status: $status), attempt $attempt/$max_attempts..."
        sleep 5
    done
    
    log_error "Hasura failed to become healthy"
    exit 1
}

# Track all tables in Hasura
track_all_tables() {
    local endpoint="$1"
    local secret="$2"
    
    log_info "Tracking all PostgreSQL tables in Hasura..."
    
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "${endpoint}/v1/metadata" \
        -H "X-Hasura-Admin-Secret: ${secret}" \
        -H "Content-Type: application/json" \
        -d '{
            "type": "pg_track_all_tables",
            "args": {
                "source": "default",
                "schema": "public"
            }
        }' 2>/dev/null)
    
    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]]; then
        log_info "Successfully tracked all tables!"
        return 0
    else
        # Check if it's just "already tracked" errors (which is fine)
        if echo "$body" | grep -q "already tracked"; then
            log_info "Tables already tracked (this is fine)"
            return 0
        fi
        
        log_error "Failed to track tables (HTTP $http_code): $body"
        exit 1
    fi
}

# Get table count for verification
verify_tables() {
    local endpoint="$1"
    local secret="$2"
    
    log_info "Verifying tracked tables..."
    
    local response
    response=$(curl -s -X POST "${endpoint}/v1/metadata" \
        -H "X-Hasura-Admin-Secret: ${secret}" \
        -H "Content-Type: application/json" \
        -d '{
            "type": "pg_get_source_tables",
            "args": {
                "source": "default"
            }
        }' 2>/dev/null)
    
    local count
    count=$(echo "$response" | grep -o '"name"' | wc -l | tr -d ' ')
    
    log_info "Tracked $count tables in Hasura"
}

# Main execution
main() {
    log_info "Starting post-deployment configuration..."
    log_info "Resource Group: $RESOURCE_GROUP"
    log_info "CitrineOS App: $CITRINEOS_APP"
    log_info "Hasura App: $HASURA_APP"
    echo ""
    
    # Get Hasura configuration
    local hasura_endpoint
    hasura_endpoint=$(get_hasura_endpoint)
    log_info "Hasura endpoint: $hasura_endpoint"
    
    local hasura_secret
    hasura_secret=$(get_hasura_secret)
    if [[ -z "$hasura_secret" ]]; then
        log_error "Failed to retrieve Hasura admin secret"
        exit 1
    fi
    log_info "Retrieved Hasura admin secret"
    
    # Wait for services
    wait_for_migrations
    wait_for_hasura "$hasura_endpoint"
    
    # Configure Hasura
    track_all_tables "$hasura_endpoint" "$hasura_secret"
    verify_tables "$hasura_endpoint" "$hasura_secret"
    
    echo ""
    log_info "Post-deployment configuration complete!"
    log_info "Hasura Console: ${hasura_endpoint}/console"
}

main "$@"
