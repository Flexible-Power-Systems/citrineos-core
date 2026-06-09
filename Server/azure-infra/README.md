# CitrineOS Azure Infrastructure

**Deploy CitrineOS to Azure Container Apps - Zero clicking required!**

## Quick Start

### Full Deployment (from scratch)

```bash
# Deploy everything with a single command
./scripts/bootstrap.sh dev

# Or with custom settings
AZURE_LOCATION=eastus IMAGE_TAG=v1.2.0 ./scripts/bootstrap.sh prod
```

This creates:
- Resource Group
- Azure Container Registry (ACR)
- PostgreSQL Flexible Server (with pgcrypto, postgis, citext extensions)
- Container Apps Environment
- CitrineOS Container App (OCPP 2.0.1 core)
- CitrineOS OCPI Container App (OCPI 2.2.1 module)
- Hasura GraphQL Container App
- RabbitMQ Container App (message broker)
- Operator UI Container App
- Key Vault (for secrets)
- Storage Account

**Time:** ~15-20 minutes

### Update Deployment (after code changes)

```bash
# Pull upstream changes, then redeploy
./scripts/deploy.sh dev v1.1.0
```

### Teardown (delete everything)

```bash
./scripts/teardown.sh dev
```

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/bootstrap.sh` | Full deployment from scratch (creates everything) |
| `scripts/deploy.sh` | Update existing deployment (build → deploy → configure) |
| `scripts/post-deploy.sh` | Just post-deployment (track Hasura tables) |
| `scripts/deploy-everest-emulator.sh` | Deploy EVerest charger emulator for testing |
| `scripts/teardown.sh` | Delete all resources (with confirmation) |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Azure Container Apps                         │
│  ┌─────────────────────┐    ┌─────────────────────┐             │
│  │   CitrineOS Core    │    │   Hasura GraphQL    │             │
│  │   (OCPP Server)     │    │   (API Gateway)     │             │
│  │   Port 8081 (WS)    │    │   Port 8080         │             │
│  │   Port 8080 (REST)  │    │                     │             │
│  └──────────┬──────────┘    └──────────┬──────────┘             │
│             │                          │                         │
│  ┌─────────────────────┐    ┌─────────────────────┐             │
│  │  CitrineOS OCPI     │    │   Operator UI       │             │
│  │  (OCPI 2.2.1)       │    │   (Web Frontend)    │             │
│  │  Port 8085          │    │   Port 3000          │             │
│  └──────────┬──────────┘    └──────────┬──────────┘             │
│             │                          │                         │
│  ┌─────────────────────┐               │                         │
│  │   RabbitMQ          │               │                         │
│  │   (Message Broker)  │               │                         │
│  │   Port 5672 (TCP)   │               │                         │
│  └──────────┬──────────┘               │                         │
│             │                          │                         │
│             └──────────┬───────────────┘                         │
│                        │                                         │
│  ┌─────────────────────▼─────────────────────┐                  │
│  │       Azure PostgreSQL Flexible Server     │                  │
│  │       Extensions: pgcrypto, postgis,       │                  │
│  │                   citext                   │                  │
│  └────────────────────────────────────────────┘                  │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │  Key Vault   │  │     ACR      │  │   Storage    │           │
│  │  (Secrets)   │  │   (Images)   │  │   (Blobs)    │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│               Azure Container Instances (ACI)                    │
│  ┌─────────────────────────────────────┐                         │
│  │   EVerest Emulator (Testing Only)   │                         │
│  │   mqtt-server + manager + nodered   │                         │
│  │   Ports: 1880 (Node-RED), 8888      │                         │
│  └─────────────────────────────────────┘                         │
└─────────────────────────────────────────────────────────────────┘
```
│             │                          │                         │
│             └──────────┬───────────────┘                         │
│                        │                                         │
│  ┌─────────────────────▼─────────────────────┐                  │
│  │       Azure PostgreSQL Flexible Server     │                  │
│  │       Extensions: pgcrypto, postgis,       │                  │
│  │                   citext                   │                  │
│  └────────────────────────────────────────────┘                  │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │  Key Vault   │  │     ACR      │  │   Storage    │           │
│  │  (Secrets)   │  │   (Images)   │  │   (Blobs)    │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

## Endpoints (after deployment)

| Service | URL Pattern |
|---------|-------------|
| CitrineOS HTTP | `https://ca-{env}-citrineos.{domain}` |
| OCPP WebSocket | `wss://ca-{env}-citrineos.{domain}/{charger_id}` |
| Hasura Console | `https://ca-{env}-hasura.{domain}/console` |
| Hasura GraphQL | `https://ca-{env}-hasura.{domain}/v1/graphql` |
| OCPI Health | `https://ca-{env}-citrineos-ocpi.{domain}/ocpi/health` |
| OCPI Swagger | `https://ca-{env}-citrineos-ocpi.{domain}/ocpi/swagger` |
| OCPI Versions | `https://ca-{env}-citrineos-ocpi.{domain}/ocpi/versions` |
| Operator UI | `https://ca-{env}-operator-ui.{domain}` |
| RabbitMQ (internal) | `amqp://ca-{env}-rabbitmq.internal.{domain}:5672` |
| Emulator Node-RED | `http://aci-{env}-everest-emulator.{region}.azurecontainer.io:1880/ui` |
| Emulator Logs | `http://aci-{env}-everest-emulator.{region}.azurecontainer.io:8888` |

## Environment Variables

CitrineOS requires environment variables with the `BOOTSTRAP_CITRINEOS_` prefix:

| Variable | Description |
|----------|-------------|
| `BOOTSTRAP_CITRINEOS_DATABASE_HOST` | PostgreSQL server hostname |
| `BOOTSTRAP_CITRINEOS_DATABASE_PORT` | PostgreSQL port (5432) |
| `BOOTSTRAP_CITRINEOS_DATABASE_USER` | Database username |
| `BOOTSTRAP_CITRINEOS_DATABASE_PASSWORD` | Database password (from secret) |
| `BOOTSTRAP_CITRINEOS_DATABASE_NAME` | Database name |
| `BOOTSTRAP_CITRINEOS_DATABASE_SSL_REQUIRE` | Must be `true` for Azure |

## Handling Upstream Schema Changes

When pulling upstream CitrineOS changes that include new migrations:

1. Run `./scripts/deploy.sh dev v1.x.x`
2. The script automatically:
   - Builds new image with updated migrations
   - Deploys to Container Apps
   - Migrations run on startup
   - New tables tracked in Hasura via API

**No manual Hasura configuration needed!**

## Files

- `container-apps-deploy.bicep` - Main infrastructure template
- `scripts/` - Deployment automation
  --registry $ACR_NAME \
