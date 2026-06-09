# Azure Dev Environment - Service Links

All services deployed in resource group `rg-citrine-os-dev` (UK South).

## Container Apps

| Service | URL |
|---------|-----|
| **CitrineOS Core** | https://ca-dev-citrineos.livelystone-879ce39c.uksouth.azurecontainerapps.io |
| **OCPP WebSocket** | wss://ca-dev-citrineos.livelystone-879ce39c.uksouth.azurecontainerapps.io/cp001 |
| **Hasura Console** | https://ca-dev-hasura.livelystone-879ce39c.uksouth.azurecontainerapps.io/console |
| **Hasura GraphQL** | https://ca-dev-hasura.livelystone-879ce39c.uksouth.azurecontainerapps.io/v1/graphql |
| **OCPI Health** | https://ca-dev-citrineos-ocpi.livelystone-879ce39c.uksouth.azurecontainerapps.io/ocpi/health |
| **OCPI Swagger** | https://ca-dev-citrineos-ocpi.livelystone-879ce39c.uksouth.azurecontainerapps.io/ocpi/swagger |
| **OCPI Versions** | https://ca-dev-citrineos-ocpi.livelystone-879ce39c.uksouth.azurecontainerapps.io/ocpi/versions |
| **Operator UI** | https://ca-dev-operator-ui.livelystone-879ce39c.uksouth.azurecontainerapps.io |
| **RabbitMQ (internal)** | amqp://ca-dev-rabbitmq.internal.livelystone-879ce39c.uksouth.azurecontainerapps.io:5672 |

## EVerest Emulator (ACI)

| Service | URL |
|---------|-----|
| **Node-RED Control Panel** | http://aci-dev-everest-emulator.uksouth.azurecontainer.io:1880/ui |
| **Node-RED Editor** | http://aci-dev-everest-emulator.uksouth.azurecontainer.io:1880 |
| **OCPP Logs** | http://aci-dev-everest-emulator.uksouth.azurecontainer.io:8888 |

## Internal Container-to-Container URLs

These are only accessible from within the Container Apps Environment:

| Service | Internal URL |
|---------|-------------|
| CitrineOS REST API | http://ca-dev-citrineos.internal.livelystone-879ce39c.uksouth.azurecontainerapps.io:8080 |
| RabbitMQ AMQP | amqp://ca-dev-rabbitmq.internal.livelystone-879ce39c.uksouth.azurecontainerapps.io:5672 |
| Hasura GraphQL | https://ca-dev-hasura.livelystone-879ce39c.uksouth.azurecontainerapps.io/v1/graphql |

## Azure Portal

| Resource | Type |
|----------|------|
| Resource Group | [rg-citrine-os-dev](https://portal.azure.com/#@/resource/subscriptions/*/resourceGroups/rg-citrine-os-dev) |
| PostgreSQL | `psql-dev-citrineos.postgres.database.azure.com` |
| Container Registry | `acrdev7ost2r7mysvje.azurecr.io` |

## Credentials

| Service | Username | Password |
|---------|----------|----------|
| Operator UI | `admin@citrineos.com` | `CitrineOS!` |
| Hasura Admin | — | `myadminsecretkey` (x-hasura-admin-secret header) |
| RabbitMQ | `guest` | `guest` |
| PostgreSQL | `citrineos_admin` | (stored in Key Vault) |

## Quick Health Checks

```bash
# CitrineOS
curl -s https://ca-dev-citrineos.livelystone-879ce39c.uksouth.azurecontainerapps.io/ | head -5

# OCPI
curl -s https://ca-dev-citrineos-ocpi.livelystone-879ce39c.uksouth.azurecontainerapps.io/ocpi/health

# Hasura
curl -s https://ca-dev-hasura.livelystone-879ce39c.uksouth.azurecontainerapps.io/healthz

# Operator UI
curl -s -o /dev/null -w "%{http_code}" https://ca-dev-operator-ui.livelystone-879ce39c.uksouth.azurecontainerapps.io

# Emulator Node-RED
curl -s -o /dev/null -w "%{http_code}" http://aci-dev-everest-emulator.uksouth.azurecontainer.io:1880/ui
```

## Useful Azure CLI Commands

```bash
# View all container apps
az containerapp list -g rg-citrine-os-dev -o table

# View logs
az containerapp logs show -n ca-dev-citrineos -g rg-citrine-os-dev --tail 50
az containerapp logs show -n ca-dev-citrineos-ocpi -g rg-citrine-os-dev --tail 50

# Restart a container app
az containerapp revision restart -n ca-dev-citrineos -g rg-citrine-os-dev --revision <revision-name>

# Check emulator
az container logs -n aci-dev-everest-emulator -g rg-citrine-os-dev --container-name manager --tail 30

# List ACR images
az acr repository list --name acrdev7ost2r7mysvje -o table
az acr repository show-tags --name acrdev7ost2r7mysvje --repository citrineos-ocpi -o table
```
