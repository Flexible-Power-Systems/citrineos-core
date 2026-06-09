# Azure Deployment Troubleshooting Guide

Known issues, gotchas, and solutions encountered during CitrineOS Azure deployment.

## RabbitMQ Exchange Not Created Automatically

**Symptom:** CitrineOS logs show `NOT_FOUND - no exchange 'citrineos' in vhost '/'`. OCPP commands (RemoteStart, Reset, etc.) never reach the charger.

**Root Cause:** When the RabbitMQ container app is deployed fresh or restarted (and `durable: false`), the `citrineos` exchange does not persist. CitrineOS expects the exchange to exist but its receiver code uses `assertExchange` only on the consumer side — if the producer publishes before any consumer has connected, the exchange may not exist yet.

**Fix:** Create the exchange manually inside the RabbitMQ container:

```bash
# Get the container app revision
REVISION=$(az containerapp revision list -n ca-dev-rabbitmq -g rg-citrine-os-dev --query "[0].name" -o tsv)

# Exec into the container and create the exchange
az containerapp exec -n ca-dev-rabbitmq -g rg-citrine-os-dev --revision "$REVISION" --command "rabbitmqadmin declare exchange name=citrineos type=headers durable=false"
```

> **CRITICAL:** The exchange type MUST be `headers`, NOT `topic`. CitrineOS source code uses `channel.assertExchange(this.exchange, 'headers', { durable: false })`. Using the wrong type causes: `PRECONDITION_FAILED - inequivalent arg 'type' for exchange 'citrineos'` and crashes CitrineOS.

**Prevention:** After any RabbitMQ restart, verify the exchange exists before restarting CitrineOS. Consider adding an init script or sidecar that creates the exchange on startup.

---

## OCPI Startup Probe Path

**Symptom:** OCPI container app keeps restarting, never becomes healthy.

**Root Cause:** The OCPI Koa server uses `routePrefix: '/ocpi'`, so the health endpoint is at `/ocpi/health`, not `/health`.

**Fix:** Ensure the startup probe in the Bicep template (or manual config) uses path `/ocpi/health`:

```bicep
probes: [
  {
    type: 'Startup'
    httpGet: {
      path: '/ocpi/health'   // NOT /health
      port: 8085
    }
    initialDelaySeconds: 10
    periodSeconds: 10
    failureThreshold: 30
  }
]
```

---

## Hasura Relationships Lost After Deployment

**Symptom:** Operator UI queries fail with errors like `field "ChargingStations" not found in type: 'public_Locations'`. The Hasura console shows tables are tracked but no relationships exist.

**Root Cause:** Hasura metadata (table tracking + relationships) is not persisted when the container is redeployed. The `post-deploy.sh` script tracks tables but does not restore relationships. Relationships are defined in the YAML metadata files at `Server/hasura-metadata/databases/default/tables/*.yaml` but are not automatically applied.

**Fix:** Apply relationships from the YAML metadata files using the Hasura metadata API:

```bash
# For each table's YAML file, create relationships via the metadata API
curl -k -X POST "https://<hasura-fqdn>/v1/metadata" \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Admin-Secret: <secret>" \
  -d '{
    "type": "pg_create_array_relationship",
    "args": {
      "source": "default",
      "table": {"schema": "public", "name": "Locations"},
      "name": "ChargingStations",
      "using": {
        "foreign_key_constraint_on": {
          "table": {"schema": "public", "name": "ChargingStations"},
          "columns": ["locationId"]
        }
      }
    }
  }'
```

There are ~205 relationships across ~55 tables. The full set is defined in the YAML files under `Server/hasura-metadata/databases/default/tables/`.

**Prevention:** Update `post-deploy.sh` to apply the full Hasura metadata (including relationships), not just track tables. Use `replace_metadata` or iterate the YAML files.

---

## OCPI AMQP Connection Blocking Startup

**Symptom:** OCPI container app fails startup probe because the AMQP connection to RabbitMQ times out or fails, blocking the HTTP server from starting.

**Root Cause:** The OCPI server originally initialized AMQP connections synchronously before starting the Koa HTTP server. If RabbitMQ was not ready, the entire startup blocked.

**Fix:** Modified `citrineos-ocpi/00_Base/src/index.ts` to start the HTTP server FIRST, then initialize AMQP connections in the background:

```typescript
// Start Koa server immediately (for health probes)
this.app.listen(port, () => { ... });

// Then initialize AMQP connections in background (non-blocking)
this.initializeModules().catch(err => { ... });
```

---

## PostgreSQL SSL Required for Azure

**Symptom:** OCPI module fails to connect to PostgreSQL with SSL errors.

**Root Cause:** Azure PostgreSQL Flexible Server requires SSL connections. The OCPI Sequelize config did not include SSL dialect options.

**Fix:** Added SSL configuration to `citrineos-ocpi/Server/src/config/sequelize.bridge.config.ts`:

```typescript
dialectOptions: {
  ssl: {
    require: true,
    rejectUnauthorized: false  // Azure uses Microsoft-managed certs
  }
}
```

Enable via env var: `DB_SSL=true`

---

## EVerest Emulator Configuration

### Connecting to Azure CitrineOS

The emulator connects via WebSocket to CitrineOS. The URL is set during deployment:

```
wss://ca-dev-citrineos.livelystone-879ce39c.uksouth.azurecontainerapps.io/cp001
```

The emulator Bicep template (`everest-emulator.bicep`) handles:
- Setting `EVEREST_TARGET_URL` environment variable
- Enabling wildcard certificate verification for Azure TLS
- Configuring OCPP 2.0.1 security profile based on `wss://` vs `ws://`

### Using the Node-RED UI

The emulator control panel is at:
```
http://aci-dev-everest-emulator.uksouth.azurecontainer.io:1880/ui
```

Key operations:
1. **Plug in car:** Click "Car Plugin" button on Connector 1
2. **Swipe RFID:** Select token (e.g., DEADBEEF) and click "Swipe RFID"
3. **Remote start:** Use Operator UI → Charging Stations → Start Transaction (requires car plugged in first)
4. **Stop charging:** Click "Stop & Unplug" on the emulator

### Charger Identity

The emulator registers as charger `cp001`. This ID is set in the WebSocket URL path and in the emulator's SQLite device model database.

### Troubleshooting Emulator Connection

```bash
# Check emulator logs
az container logs -n aci-dev-everest-emulator -g rg-citrine-os-dev --container-name manager --follow

# Check if cp001 is connected to CitrineOS
az containerapp logs show -n ca-dev-citrineos -g rg-citrine-os-dev --tail 20 | grep cp001

# Restart emulator
az container restart -n aci-dev-everest-emulator -g rg-citrine-os-dev
```

---

## Container App Internal DNS

Container apps within the same environment communicate via internal DNS:

```
ca-{env}-{name}.internal.{environment-domain}:{port}
```

Example:
```
ca-dev-rabbitmq.internal.livelystone-879ce39c.uksouth.azurecontainerapps.io:5672
ca-dev-citrineos.internal.livelystone-879ce39c.uksouth.azurecontainerapps.io:8080
```

The environment domain is unique per Container Apps Environment and does not change between deployments.

---

## OCPI Environment Variables Reference

| Variable | Value | Notes |
|----------|-------|-------|
| `APP_NAME` | `all` | Module selection |
| `APP_ENV` | `docker` | Config profile |
| `DB_HOST` | `psql-dev-citrineos.postgres.database.azure.com` | Azure PostgreSQL FQDN |
| `DB_PORT` | `5432` | Standard PostgreSQL port |
| `DB_NAME` | `citrineos` | Shared database with core |
| `DB_USER` | `citrineos_admin` | Database admin user |
| `DB_PASS` | (secret) | From Key Vault |
| `DB_SSL` | `true` | Required for Azure PostgreSQL |
| `GRAPHQL_ENDPOINT` | `https://ca-dev-hasura.../v1/graphql` | Hasura GraphQL endpoint |
| `GRAPHQL_HEADERS` | `{"x-hasura-admin-secret":"..."}` | JSON string with auth header |
| `AMQP_URL` | `amqp://guest:guest@ca-dev-rabbitmq.internal...:5672` | RabbitMQ internal URL |
| `AMQP_EXCHANGE` | `ocpi` | OCPI uses its own exchange, not `citrineos` |
| `LOG_LEVEL` | `2` | 0=error, 1=warn, 2=info, 3=debug |
