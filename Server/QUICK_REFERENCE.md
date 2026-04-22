# CitrineOS Quick Command Reference

## 🚀 Start Everything

```bash
# 1. Start Docker services
cd .
docker-compose up -d

# 2. Start ngrok tunnels
ngrok start --all --config /tmp/ngrok-citrineos-priority.yml --log=stdout &

# 3. Start Operator UI (optional)
cd ../citrineos-operator-ui
nvm use && npm run dev &
```

## 🛑 Stop Everything

```bash
# 1. Stop Docker services
cd .
docker-compose down

# 2. Stop ngrok
pkill ngrok

# 3. Stop Operator UI
pkill -f "npm run dev"
```

## 📊 Check Status

```bash
# Docker containers
docker ps

# Ngrok tunnels
curl -s http://localhost:4040/api/tunnels | jq -r '.tunnels[] | {name, public_url}'

# CitrineOS logs (live)
docker logs -f server-citrine-1
```

## 🔍 Debug Charger Connection

```bash
# Check if charger is connected
docker logs server-citrine-1 2>&1 | grep "AE5044L1GR1C00007W" | tail -20

# Check WebSocket servers are running
docker logs server-citrine-1 2>&1 | grep "WebsocketServer running"

# Monitor new connections
docker logs -f server-citrine-1 2>&1 | grep -E "Successfully registered|Connection|Protocol"

# Check ngrok traffic
curl -s http://localhost:4040/api/requests/http | jq -r '.requests[0:10]'
```

## 📋 Charger Configuration

### OCPP 1.6 (Verified Working ✅)
```
URL: wss://ocpp16-fps.ngrok.app/AE5044L1GR1C00007W
Protocol: WSS
Port: 443
```

### OCPP 2.0.1 (Untested)
```
URL: wss://ocpp201-sp0-fps.ngrok.app/AE5044L1GR1C00007W
Protocol: WSS
Port: 443
Security Profile: 0
```

## 🌐 Access URLs

- **Operator UI**: https://citrine-operator-ui-fps.ngrok.app
- **Hasura Console**: http://localhost:8080/console
- **GraphQL API**: https://citrine-asura-fps.ngrok.app/v1/graphql
- **Ngrok Inspector**: http://localhost:4040

## 🔧 Troubleshooting

### Container won't start
```bash
docker-compose down -v
docker-compose up -d
docker logs -f server-citrine-1
```

### Charger not connecting
```bash
# 1. Check ngrok is running
curl http://localhost:4040/api/tunnels

# 2. Test endpoint
curl -I https://ocpp16-fps.ngrok.app/AE5044L1GR1C00007W

# 3. Watch for connection attempts
docker logs -f server-citrine-1 2>&1 | grep -i "AE5044L1GR1C00007W"
```

### Database issues
```bash
# Restart PostgreSQL
docker-compose restart ocpp-db

# Check database logs
docker logs server-ocpp-db-1
```

## 🗂️ Important Files

- **Docker Compose**: `~/github/citrineos/citrineos-core/Server/docker-compose.yml`
- **Ngrok Config**: `/tmp/ngrok-citrineos-priority.yml`
- **Operator UI**: `~/github/citrineos/citrineos-operator-ui/`
- **Data Directory**: `~/github/citrineos/citrineos-core/Server/data/`

## ☁️ Azure Deployment

```bash
# Login to Azure
az login

# Deploy infrastructure
cd ~/github/citrineos/citrineos-core/Server/azure-infra
az deployment sub create \
  --location eastus \
  --template-file main.bicep \
  --parameters environmentName=citrineos
```

## 📝 Documentation

- **Full Setup Guide**: `SETUP_SUMMARY.md`
- **Azure Guide**: `AZURE_DEPLOYMENT_GUIDE.md`
- **This Reference**: `QUICK_REFERENCE.md`
