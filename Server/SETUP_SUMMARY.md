# CitrineOS Local Development Setup Summary

## Overview
This document captures the setup and configuration for running CitrineOS OCPP server locally with ngrok tunneling for remote charger connectivity.

## What Was Accomplished

### 1. Local Docker Environment
Successfully configured and ran CitrineOS using Docker Compose with the following services:
- **CitrineOS Core** (server-citrine-1): OCPP server on ports 8081 (OCPP 2.0.1 SP0), 8082 (OCPP 2.0.1 SP1), 8092 (OCPP 1.6)
- **PostgreSQL** (server-ocpp-db-1): Database backend
- **RabbitMQ** (server-amqp-broker-1): Message broker
- **Hasura GraphQL** (server-graphql-engine-1): GraphQL API on port 8080
- **MinIO**: Object storage

### 2. Ngrok Tunneling Configuration
Created persistent ngrok tunnels to expose local OCPP endpoints publicly:

**Ngrok Config File**: `/tmp/ngrok-citrineos-priority.yml`
```yaml
version: 2
authtoken: YOUR_AUTHTOKEN_HERE
tunnels:
  ocpp16:
    proto: http
    addr: 8092
    domain: ocpp16-fps.ngrok.app
    inspect: true
  ocpp201-sp0:
    proto: http
    addr: 8081
    domain: ocpp201-sp0-fps.ngrok.app
    inspect: true
  ocpp201-sp1:
    proto: http
    addr: 8082
    domain: ocpp201-sp1-fps.ngrok.app
    inspect: true
  operator-ui:
    proto: http
    addr: 3000
    domain: operator-ui-fps.ngrok.app
    inspect: true
```

**Public Endpoints**:
- OCPP 1.6: `wss://ocpp16-fps.ngrok.app`
- OCPP 2.0.1 SP0: `wss://ocpp201-sp0-fps.ngrok.app`
- OCPP 2.0.1 SP1: `wss://ocpp201-sp1-fps.ngrok.app`
- Operator UI: `https://operator-ui-fps.ngrok.app`

### 3. Charger Integration Testing
- **Charger**: AE5044L1GR1C00007W
- **Successfully connected via**: OCPP 1.6
- **Tested operations**: RemoteStartTransaction, RemoteStopTransaction, StatusNotification, Heartbeat
- **OCPP 2.0.1 connection**: Attempted but charger may not support this protocol version

## Quick Start Guide

### Prerequisites
- Docker & Docker Compose installed
- ngrok account with reserved domains
- Node.js (for operator UI)

### Step 1: Start CitrineOS Backend
```bash
cd .
docker-compose up -d
```

### Step 2: Start Ngrok Tunnels
```bash
ngrok start --all --config /tmp/ngrok-citrineos-priority.yml --log=stdout
```

### Step 3: Start Operator UI (Optional)
```bash
cd ../citrineos-operator-ui
nvm use
npm run dev
```

### Step 4: Monitor Logs
```bash
# CitrineOS logs
docker logs -f server-citrine-1

# Filter for specific charger
docker logs -f server-citrine-1 2>&1 | grep "AE5044L1GR1C00007W"

# Check ngrok inspector
# Open http://localhost:4040 in browser
```

### Step 5: Configure Charger
Use the following connection settings on your EV charger:

**For OCPP 1.6**:
- Server URL: `wss://ocpp16-fps.ngrok.app/{CHARGER_ID}`
- Port: 443
- Protocol: WSS
- Example: `wss://ocpp16-fps.ngrok.app/AE5044L1GR1C00007W`

**For OCPP 2.0.1 (if supported)**:
- Server URL: `wss://ocpp201-sp0-fps.ngrok.app/{CHARGER_ID}`
- Port: 443
- Protocol: WSS
- Security Profile: 0 (no TLS auth)
- Example: `wss://ocpp201-sp0-fps.ngrok.app/AE5044L1GR1C00007W`

⚠️ **Important**: Remove any trailing slashes from URLs!

## Useful Commands

### Docker Management
```bash
# Stop all services
docker-compose down

# Restart a specific service
docker-compose restart citrine

# View all running containers
docker ps

# Clean up (including volumes)
docker-compose down -v
```

### Debugging
```bash
# Check WebSocket servers are running
docker logs server-citrine-1 2>&1 | grep "WebsocketServer running"

# Monitor connections in real-time
docker logs -f server-citrine-1 2>&1 | grep -E "Successfully registered|Connection closed|Protocol mismatch"

# Check ngrok tunnels status
curl -s http://localhost:4040/api/tunnels | jq -r '.tunnels[] | {name, public_url}'

# View recent ngrok requests
curl -s http://localhost:4040/api/requests/http | jq -r '.requests[0:10] | .[] | "\(.start) \(.method) \(.uri) -> \(.response.status)"'
```

### Access Points
- **Hasura Console**: http://localhost:8080/console
- **Ngrok Inspector**: http://localhost:4040
- **Operator UI**: http://localhost:3000 or https://operator-ui-fps.ngrok.app
- **GraphQL API**: http://localhost:8080/v1/graphql

## Known Issues & Solutions

### Issue: Charger not connecting
**Solutions**:
1. Verify ngrok tunnels are running: `curl http://localhost:4040/api/tunnels`
2. Check CitrineOS is listening: `docker logs server-citrine-1 | grep "WebsocketServer running"`
3. Ensure no trailing slash in charger URL configuration
4. Test endpoint accessibility: `curl -I https://ocpp16-fps.ngrok.app/{CHARGER_ID}`

### Issue: OCPP 2.0.1 connection fails
**Possible causes**:
- Charger firmware may not support OCPP 2.0.1
- Check charger documentation for supported protocols
- Try OCPP 1.6 as fallback

### Issue: Docker containers won't start
**Solutions**:
```bash
# Clean up and restart
docker-compose down -v
docker-compose up -d

# Check for port conflicts
lsof -i :8080 -i :8081 -i :8082 -i :8092
```

## Network Architecture

```
EV Charger
    |
    | (WSS over internet)
    |
    v
Ngrok Cloud
    |
    | (HTTP/WebSocket)
    |
    v
Local Ngrok Client (localhost)
    |
    | (HTTP/WebSocket)
    |
    v
CitrineOS (Docker)
    ├── Port 8080: Hasura GraphQL
    ├── Port 8081: OCPP 2.0.1 Security Profile 0
    ├── Port 8082: OCPP 2.0.1 Security Profile 1
    └── Port 8092: OCPP 1.6
```

## File Locations

- **Docker Compose**: `./docker-compose.yml`
- **Ngrok Config**: `/tmp/ngrok-citrineos-priority.yml`
- **Operator UI**: `../citrineos-operator-ui`
- **Data/Logs**: `./data/`

## Next Steps: Azure Deployment

### Recommended Azure Architecture
1. **Azure Container Instances (ACI)** or **Azure Kubernetes Service (AKS)** for CitrineOS
2. **Azure Database for PostgreSQL** - Managed database
3. **Azure Service Bus** or **RabbitMQ on ACI** - Message broker
4. **Azure Application Gateway** - Load balancer with WebSocket support
5. **Azure Storage Account** - For MinIO replacement
6. **Azure Front Door** or **Application Gateway** - Public HTTPS/WSS endpoints

### Infrastructure as Code Options
- **Bicep**: Native Azure IaC (recommended for Azure-only)
- **Terraform**: Multi-cloud support
- **ARM Templates**: Azure Resource Manager templates
- **Pulumi**: Programming language-based IaC

Would you like help creating the Azure IaC templates?

## Testing Checklist

- [ ] Docker services all running: `docker ps`
- [ ] Ngrok tunnels active: `curl http://localhost:4040/api/tunnels`
- [ ] CitrineOS WebSocket servers listening
- [ ] Charger connects successfully
- [ ] Can send RemoteStartTransaction command
- [ ] Can send RemoteStopTransaction command
- [ ] StatusNotification messages received
- [ ] Heartbeat messages received

## Support & Resources

- CitrineOS Documentation: https://github.com/citrineos/citrineos-core
- OCPP 1.6 Specification: https://www.openchargealliance.org/protocols/ocpp-16/
- OCPP 2.0.1 Specification: https://www.openchargealliance.org/protocols/ocpp-201/
- Ngrok Documentation: https://ngrok.com/docs

---

**Last Updated**: 2026-04-21
**Environment**: macOS local development
**Status**: OCPP 1.6 validated ✅ | OCPP 2.0.1 pending charger support
