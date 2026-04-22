# CitrineOS Azure Quick Deploy

**Deploy CitrineOS to Azure in under 30 minutes** using Infrastructure as Code (Bicep).

## Prerequisites

1. Azure CLI installed: `brew install azure-cli`
2. Access to an Azure resource group (provided by DevOps team)
3. Azure subscription with appropriate permissions

## 🚀 Quick Start

### Option 1: Azure Container Apps (Recommended)

Container Apps provides built-in HTTPS, auto-scaling, and WebSocket support for OCPP.

```bash
# Navigate to Server directory
cd Server/

# Make script executable
chmod +x deploy-container-apps.sh

# Deploy (replace YOUR_RESOURCE_GROUP with actual name)
./deploy-container-apps.sh YOUR_RESOURCE_GROUP

# Or if you have existing PostgreSQL server:
./deploy-container-apps.sh YOUR_RESOURCE_GROUP existing-postgres-server-name.postgres.database.azure.com
```

**What it does:**
1. Creates Azure Container Registry
2. Deploys PostgreSQL database (or uses existing)
3. Creates Container Apps Environment with Log Analytics
4. Deploys Hasura GraphQL engine with HTTPS
5. Builds CitrineOS container image
6. Deploys CitrineOS to Container Apps with auto-TLS

**Benefits:**
- ✅ Automatic HTTPS/TLS certificates
- ✅ WebSocket support for OCPP 1.6 and 2.0.1
- ✅ Auto-scaling (0-5 replicas)
- ✅ No ACI quota limitations

**Time:** ~15-20 minutes

---

### Option 2: Azure Container Instances (Legacy)

Use this if you need simpler deployment or have specific ACI requirements.

```bash
cd Server/
chmod +x deploy-to-azure.sh
./deploy-to-azure.sh YOUR_RESOURCE_GROUP
```

**Note:** ACI has regional core quota limits (typically 10 cores).
If you hit `ContainerGroupQuotaReached` errors, use Container Apps instead.

**Time:** ~15-20 minutes

---

### Option 2: Manual Deployment

If you prefer step-by-step control:

#### 1. Login to Azure
```bash
az login
az account set --subscription "YOUR_SUBSCRIPTION_NAME"
```

#### 2. Deploy Infrastructure
```bash
cd .

az deployment group create \
  --resource-group YOUR_RESOURCE_GROUP \
  --template-file azure-infra/quick-deploy.bicep \
  --parameters \
    environmentName=dev \
    postgresPassword="YOUR_SECURE_PASSWORD"
```

#### 3. Build and Push Container
```bash
# Get ACR name from deployment
ACR_NAME=$(az deployment group show \
  --resource-group YOUR_RESOURCE_GROUP \
  --name YOUR_DEPLOYMENT_NAME \
  --query properties.outputs.acrName.value -o tsv)

# Login to ACR
az acr login --name $ACR_NAME

# Build and push image
az acr build \
  --registry $ACR_NAME \
  --image citrineos/core:v1.0.0 \
  --file local.Dockerfile \
  .
```

#### 4. Update Container
```bash
# Get ACR credentials
ACR_LOGIN_SERVER=$(az acr show --name $ACR_NAME --query loginServer -o tsv)
ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --query passwords[0].value -o tsv)

# Deploy container
az container create \
  --resource-group YOUR_RESOURCE_GROUP \
  --name aci-dev-citrineos \
  --image ${ACR_LOGIN_SERVER}/citrineos/core:v1.0.0 \
  --cpu 2 \
  --memory 4 \
  --ports 8081 8082 8092 \
  --registry-login-server $ACR_LOGIN_SERVER \
  --registry-password $ACR_PASSWORD
```

---

## 📡 Configure Your Charger

After deployment, configure your charger with:

```
OCPP 1.6 Endpoint:
ws://YOUR-CITRINEOS-FQDN.eastus.azurecontainer.io:8092/AE5044L1GR1C00007W

OCPP 2.0.1 Endpoint:
ws://YOUR-CITRINEOS-FQDN.eastus.azurecontainer.io:8081/AE5044L1GR1C00007W
```

Replace `YOUR-CITRINEOS-FQDN` with the actual FQDN from deployment output.

---

## 🔍 Monitoring & Debugging

### View Container Logs
```bash
az container logs \
  --resource-group YOUR_RESOURCE_GROUP \
  --name aci-dev-citrineos \
  --follow
```

### Check Container Status
```bash
az container show \
  --resource-group YOUR_RESOURCE_GROUP \
  --name aci-dev-citrineos \
  --query instanceView.state
```

### Restart Container
```bash
az container restart \
  --resource-group YOUR_RESOURCE_GROUP \
  --name aci-dev-citrineos
```

### Access Hasura Console
```bash
# Get Hasura URL from deployment
HASURA_URL=$(az deployment group show \
  --resource-group YOUR_RESOURCE_GROUP \
  --name YOUR_DEPLOYMENT_NAME \
  --query properties.outputs.hasuraUrl.value -o tsv)

echo "Hasura Console: ${HASURA_URL}/console"
```

---

## 💾 Database Connection

### Connect to PostgreSQL
```bash
# Connection string format:
postgresql://citrineos_admin:PASSWORD@SERVER.postgres.database.azure.com:5432/citrineos?sslmode=require

# Using psql:
psql "postgresql://citrineos_admin:PASSWORD@YOUR_SERVER:5432/citrineos?sslmode=require"
```

### Using Existing Dev Database

If your DevOps team provided an existing PostgreSQL server:

```bash
./deploy-to-azure.sh YOUR_RESOURCE_GROUP your-existing-postgres.postgres.database.azure.com
```

The deployment will:
- Skip creating a new PostgreSQL server
- Connect CitrineOS and Hasura to your existing database
- Create the `citrineos` database if it doesn't exist

---

## 📊 Cost Estimate

**Development Setup (this deployment):**
- Container Registry (Basic): ~$5/month
- PostgreSQL (Burstable B2s): ~$30/month
- Container Instances (2 CPU, 4GB): ~$60/month
- Storage Account: ~$5/month
- **Total: ~$100/month**

**To reduce costs:**
- Stop containers when not in use: `az container stop`
- Use existing PostgreSQL server (share with other projects)
- Delete resource group when done testing

---

## 🎯 What's Included

This deployment creates:

✅ **Azure Container Registry** - Stores your CitrineOS images  
✅ **PostgreSQL Flexible Server** - Database for OCPP data  
✅ **Storage Account** - File storage (replaces MinIO)  
✅ **Log Analytics** - Centralized logging  
✅ **Hasura Container** - GraphQL API  
✅ **CitrineOS Container** - OCPP server with ports:
  - 8092: OCPP 1.6
  - 8081: OCPP 2.0.1 SP0
  - 8082: OCPP 2.0.1 SP1

---

## 🔄 Updating Your Deployment

### Rebuild and Redeploy
```bash
# Build new version
az acr build \
  --registry YOUR_ACR_NAME \
  --image citrineos/core:v1.0.1 \
  --file local.Dockerfile \
  .

# Update container (will restart automatically)
az container create --resource-group YOUR_RESOURCE_GROUP --name aci-dev-citrineos ...
```

---

## 🧹 Clean Up

### Delete Everything
```bash
az group delete --name YOUR_RESOURCE_GROUP --yes
```

### Keep Database, Delete Containers
```bash
az container delete --resource-group YOUR_RESOURCE_GROUP --name aci-dev-citrineos --yes
az container delete --resource-group YOUR_RESOURCE_GROUP --name aci-dev-hasura --yes
```

---

## 🆘 Troubleshooting

### Container won't start
```bash
# Check logs for errors
az container logs --resource-group YOUR_RESOURCE_GROUP --name aci-dev-citrineos

# Check container state
az container show \
  --resource-group YOUR_RESOURCE_GROUP \
  --name aci-dev-citrineos \
  --query instanceView
```

### Can't connect to database
```bash
# Check firewall rules
az postgres flexible-server firewall-rule list \
  --resource-group YOUR_RESOURCE_GROUP \
  --name YOUR_POSTGRES_SERVER

# Add your IP if needed
az postgres flexible-server firewall-rule create \
  --resource-group YOUR_RESOURCE_GROUP \
  --name YOUR_POSTGRES_SERVER \
  --rule-name AllowMyIP \
  --start-ip-address YOUR_IP
```

### Charger not connecting
1. Check container is running: `az container show ...`
2. Verify endpoint URL (no trailing slash!)
3. Check container logs for connection attempts
4. Test WebSocket: `wscat -c ws://YOUR-FQDN:8092/test`

---

## 🚀 Next Steps

After successful deployment:

1. ✅ **Test charger connection** with physical hardware
2. ✅ **Verify database integration** with dev DB
3. 📋 **Create fork** of CitrineOS for production
4. 🔐 **Add SSL/TLS** with Azure Application Gateway
5. 📊 **Set up monitoring** with Application Insights
6. 🔄 **Implement CI/CD** with GitHub Actions

---

## 📚 Additional Resources

- [Azure Container Instances Docs](https://learn.microsoft.com/azure/container-instances/)
- [Bicep Documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)
- [CitrineOS GitHub](https://github.com/citrineos/citrineos-core)
- [SETUP_SUMMARY.md](./SETUP_SUMMARY.md) - Local development guide
- [AZURE_DEPLOYMENT_GUIDE.md](./AZURE_DEPLOYMENT_GUIDE.md) - Full production deployment

---

**Questions?** Check the troubleshooting section or view container logs.
