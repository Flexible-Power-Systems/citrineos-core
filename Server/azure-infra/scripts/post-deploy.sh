#!/bin/bash
# Post-deployment script for CitrineOS on Azure Container Apps
# Automatically tracks all PostgreSQL tables in Hasura GraphQL

set -e

# Configuration (can be overridden via environment variables)
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-citrine-os-dev}"
CITRINEOS_APP="${CITRINEOS_APP:-ca-dev-citrineos}"
HASURA_APP="${HASURA_APP:-ca-dev-hasura}"
HASURA_ADMIN_SECRET="${HASURA_ADMIN_SECRET:-}"  # Pass from bootstrap.sh or Key Vault
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

# Get Hasura admin secret (from env var, container app, or Key Vault)
get_hasura_secret() {
    # First check if passed via environment variable
    if [[ -n "$HASURA_ADMIN_SECRET" ]]; then
        echo "$HASURA_ADMIN_SECRET"
        return 0
    fi
    
    # Try container app secrets
    local secret
    secret=$(az containerapp secret show --name "$HASURA_APP" -g "$RESOURCE_GROUP" \
        --secret-name admin-secret --query "value" -o tsv 2>/dev/null)
    
    if [[ -n "$secret" ]]; then
        echo "$secret"
        return 0
    fi
    
    # Try Key Vault (find KV in resource group)
    local kv_name
    kv_name=$(az keyvault list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null)
    
    if [[ -n "$kv_name" ]]; then
        secret=$(az keyvault secret show --vault-name "$kv_name" \
            --name hasura-admin-secret --query "value" -o tsv 2>/dev/null)
        if [[ -n "$secret" ]]; then
            echo "$secret"
            return 0
        fi
    fi
    
    echo ""
}

# Wait for CitrineOS to be ready (either migrations complete or server running)
wait_for_migrations() {
    log_info "Waiting for CitrineOS to be ready..."
    
    local elapsed=0
    local interval=10
    
    while [[ $elapsed -lt $MAX_WAIT_SECONDS ]]; do
        # Check if the container app is running
        local status
        status=$(az containerapp show --name "$CITRINEOS_APP" -g "$RESOURCE_GROUP" \
            --query "properties.runningStatus" -o tsv 2>/dev/null)
        
        if [[ "$status" == "Running" ]]; then
            log_info "CitrineOS container is running"
            # Give it a few more seconds to ensure migrations are complete
            sleep 5
            return 0
        fi
        
        log_info "Waiting for CitrineOS... status=$status (${elapsed}s / ${MAX_WAIT_SECONDS}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    log_error "Timeout waiting for CitrineOS after ${MAX_WAIT_SECONDS}s"
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

# Get list of untracked tables from database
get_untracked_tables() {
    local endpoint="$1"
    local secret="$2"
    
    # Get all tables in database
    curl -s -X POST "${endpoint}/v1/metadata" \
        -H "X-Hasura-Admin-Secret: ${secret}" \
        -H "Content-Type: application/json" \
        -d '{"type": "pg_get_source_tables", "args": {"source": "default"}}' 2>/dev/null
}

# Track all tables in Hasura using v2 API
track_all_tables() {
    local endpoint="$1"
    local secret="$2"
    
    log_info "Tracking all PostgreSQL tables in Hasura..."
    
    # Get untracked tables from public schema (excluding system tables)
    local tables_json
    tables_json=$(curl -s -X POST "${endpoint}/v1/metadata" \
        -H "X-Hasura-Admin-Secret: ${secret}" \
        -H "Content-Type: application/json" \
        -d '{"type": "pg_get_source_tables", "args": {"source": "default"}}' 2>/dev/null)
    
    # Build bulk track request for all public schema tables
    # Filter to public schema and exclude spatial_ref_sys (PostGIS system table)
    local track_args
    track_args=$(echo "$tables_json" | jq -c '[.[] | select(.schema == "public" and .name != "spatial_ref_sys") | {"table": {"schema": .schema, "name": .name}, "source": "default"}]' 2>/dev/null)
    
    if [[ -z "$track_args" ]] || [[ "$track_args" == "[]" ]] || [[ "$track_args" == "null" ]]; then
        log_warn "No untracked tables found or couldn't parse table list"
        return 0
    fi
    
    local table_count
    table_count=$(echo "$track_args" | jq 'length')
    log_info "Found $table_count tables to track"
    
    # Use postgres_track_tables (Hasura v2 API)
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST "${endpoint}/v1/metadata" \
        -H "X-Hasura-Admin-Secret: ${secret}" \
        -H "Content-Type: application/json" \
        -d "{\"type\": \"postgres_track_tables\", \"args\": {\"tables\": ${track_args}, \"allow_warnings\": true}}" 2>/dev/null)
    
    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]]; then
        log_info "Successfully tracked tables!"
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
        -d '{"type": "export_metadata", "args": {}}' 2>/dev/null)
    
    local count
    count=$(echo "$response" | jq '.sources[0].tables | length' 2>/dev/null || echo "0")
    
    log_info "Tracked $count tables in Hasura GraphQL"
}

# Create Hasura relationships required by the Operator UI
# Tracking tables alone is not enough - the UI queries join across tables
# using relationships that must be explicitly created in Hasura metadata.
create_hasura_relationships() {
    local endpoint="$1"
    local secret="$2"
    
    log_info "Creating Hasura relationships for Operator UI..."
    
    # Helper function to create a relationship (ignores "already exists" errors)
    create_relationship() {
        local rel_type="$1"
        local payload="$2"
        local desc="$3"
        
        local response
        response=$(curl -s -X POST "${endpoint}/v1/metadata" \
            -H "X-Hasura-Admin-Secret: ${secret}" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)
        
        if echo "$response" | grep -q '"message":"success"'; then
            log_info "  Created: $desc"
        elif echo "$response" | grep -q "already exists"; then
            log_info "  Exists:  $desc"
        else
            log_warn "  Failed:  $desc - $response"
        fi
    }
    
    # ChargingStations -> Location (object, via locationId FK)
    create_relationship "object" \
        '{"type":"pg_create_object_relationship","args":{"source":"default","table":"ChargingStations","name":"Location","using":{"foreign_key_constraint_on":"locationId"}}}' \
        "ChargingStations.Location"
    
    # ChargingStations -> Evses (array, via Evses.stationId FK)
    create_relationship "array" \
        '{"type":"pg_create_array_relationship","args":{"source":"default","table":"ChargingStations","name":"Evses","using":{"foreign_key_constraint_on":{"table":"Evses","column":"stationId"}}}}' \
        "ChargingStations.Evses"
    
    # ChargingStations -> LatestStatusNotifications (array)
    create_relationship "array" \
        '{"type":"pg_create_array_relationship","args":{"source":"default","table":"ChargingStations","name":"LatestStatusNotifications","using":{"foreign_key_constraint_on":{"table":"LatestStatusNotifications","column":"stationId"}}}}' \
        "ChargingStations.LatestStatusNotifications"
    
    # ChargingStations -> Transactions (array, via Transactions.stationId FK)
    create_relationship "array" \
        '{"type":"pg_create_array_relationship","args":{"source":"default","table":"ChargingStations","name":"Transactions","using":{"foreign_key_constraint_on":{"table":"Transactions","column":"stationId"}}}}' \
        "ChargingStations.Transactions"
    
    # ChargingStations -> Connectors (array, via Connectors.stationId FK)
    create_relationship "array" \
        '{"type":"pg_create_array_relationship","args":{"source":"default","table":"ChargingStations","name":"Connectors","using":{"foreign_key_constraint_on":{"table":"Connectors","column":"stationId"}}}}' \
        "ChargingStations.Connectors"
    
    # LatestStatusNotifications -> StatusNotification (object, via statusNotificationId FK)
    create_relationship "object" \
        '{"type":"pg_create_object_relationship","args":{"source":"default","table":"LatestStatusNotifications","name":"StatusNotification","using":{"foreign_key_constraint_on":"statusNotificationId"}}}' \
        "LatestStatusNotifications.StatusNotification"
    
    # Evses -> Connectors (array, via Connectors.evseId FK -> Evses.id)
    create_relationship "array" \
        '{"type":"pg_create_array_relationship","args":{"source":"default","table":"Evses","name":"Connectors","using":{"foreign_key_constraint_on":{"table":"Connectors","column":"evseId"}}}}' \
        "Evses.Connectors"
    
    log_info "Hasura relationships configured"
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
    create_hasura_relationships "$hasura_endpoint" "$hasura_secret"
    verify_tables "$hasura_endpoint" "$hasura_secret"
    
    echo ""
    log_info "Post-deployment configuration complete!"
    log_info "Hasura Console: ${hasura_endpoint}/console"
}

main "$@"
