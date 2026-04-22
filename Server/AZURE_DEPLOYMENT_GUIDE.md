# CitrineOS Azure Deployment Guide

## Azure Architecture Overview

### Recommended Architecture

```
Internet
    |
    v
Azure Application Gateway (WAF enabled)
    ├── HTTPS/WSS: 443
    |   ├── /ocpp/1.6/* → ACI OCPP 1.6 Service
    |   ├── /ocpp/2.0.1/sp0/* → ACI OCPP 2.0.1 SP0 Service
    |   ├── /ocpp/2.0.1/sp1/* → ACI OCPP 2.0.1 SP1 Service
    |   ├── /api/* → ACI Hasura/CitrineOS API
    |   └── / → Static Web App (Operator UI)
    |
    v
Azure Container Instances (ACI) or AKS
    ├── CitrineOS Core Container
    ├── Hasura GraphQL Container
    └── RabbitMQ Container (or use Azure Service Bus)
    |
    v
Azure Services
    ├── Azure Database for PostgreSQL
    ├── Azure Storage Account (replaces MinIO)
    ├── Azure Key Vault (SSL certificates & secrets)
    ├── Azure Monitor & Application Insights
    └── Azure Service Bus (optional, replaces RabbitMQ)
```

## Cost Optimization Strategies

### Option 1: Minimal Cost (Development/Testing)
- **Azure Container Instances**: Pay-per-second pricing
- **PostgreSQL Basic Tier**: 1 vCore, 50GB storage
- **Application Gateway Standard V2**: Smallest size
- **Estimated Cost**: ~$150-200/month

### Option 2: Production Ready
- **Azure Kubernetes Service (AKS)**: Better scalability
- **PostgreSQL General Purpose**: 2 vCores with HA
- **Application Gateway with WAF**: Enhanced security
- **Azure Service Bus Premium**: High throughput
- **Estimated Cost**: ~$500-800/month

### Option 3: Serverless (Lowest Cost)
- **Azure Container Apps**: Auto-scale to zero
- **PostgreSQL Flexible Server**: Burstable tier
- **Azure Static Web Apps**: Free tier for UI
- **Estimated Cost**: ~$80-150/month

## Infrastructure as Code: Bicep Templates

### 1. Resource Group Setup

```bicep
// main.bicep
targetScope = 'subscription'

param location string = 'eastus'
param environmentName string = 'citrineos'

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-${environmentName}-${location}'
  location: location
  tags: {
    environment: 'production'
    application: 'citrineos-ocpp'
  }
}

// Deploy resources
module network 'modules/network.bicep' = {
  scope: rg
  name: 'network-deployment'
  params: {
    location: location
    environmentName: environmentName
  }
}

module database 'modules/database.bicep' = {
  scope: rg
  name: 'database-deployment'
  params: {
    location: location
    environmentName: environmentName
  }
}

module storage 'modules/storage.bicep' = {
  scope: rg
  name: 'storage-deployment'
  params: {
    location: location
    environmentName: environmentName
  }
}

module containers 'modules/containers.bicep' = {
  scope: rg
  name: 'container-deployment'
  params: {
    location: location
    environmentName: environmentName
    dbConnectionString: database.outputs.connectionString
    storageConnectionString: storage.outputs.connectionString
  }
}

module appGateway 'modules/appgateway.bicep' = {
  scope: rg
  name: 'appgateway-deployment'
  params: {
    location: location
    environmentName: environmentName
    backendAddresses: containers.outputs.containerIPs
  }
}
```

### 2. PostgreSQL Database Module

```bicep
// modules/database.bicep
param location string
param environmentName string

resource postgreSQLServer 'Microsoft.DBforPostgreSQL/flexibleServers@2022-12-01' = {
  name: 'psql-${environmentName}'
  location: location
  sku: {
    name: 'Standard_B2s'
    tier: 'Burstable'
  }
  properties: {
    version: '14'
    administratorLogin: 'citrineos_admin'
    administratorLoginPassword: '${uniqueString(resourceGroup().id)}!P@ssw0rd'
    storage: {
      storageSizeGB: 128
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2022-12-01' = {
  parent: postgreSQLServer
  name: 'citrineos'
}

// Firewall rule to allow Azure services
resource firewallRule 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2022-12-01' = {
  parent: postgreSQLServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

output connectionString string = 'postgresql://${postgreSQLServer.properties.administratorLogin}:${uniqueString(resourceGroup().id)}!P@ssw0rd@${postgreSQLServer.properties.fullyQualifiedDomainName}:5432/citrineos'
output serverName string = postgreSQLServer.name
```

### 3. Storage Account Module

```bicep
// modules/storage.bicep
param location string
param environmentName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: 'st${environmentName}${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' = {
  parent: storageAccount
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  parent: blobService
  name: 'ocpp-data'
  properties: {
    publicAccess: 'None'
  }
}

output connectionString string = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
output storageName string = storageAccount.name
```

### 4. Container Instances Module

```bicep
// modules/containers.bicep
param location string
param environmentName string
param dbConnectionString string
param storageConnectionString string

// CitrineOS Core Container
resource citrineos 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: 'aci-${environmentName}-citrineos'
  location: location
  properties: {
    containers: [
      {
        name: 'citrineos-core'
        properties: {
          image: 'citrineos/citrineos:latest' // Replace with your image
          resources: {
            requests: {
              cpu: 2
              memoryInGB: 4
            }
          }
          ports: [
            { port: 8081, protocol: 'TCP' }
            { port: 8082, protocol: 'TCP' }
            { port: 8092, protocol: 'TCP' }
          ]
          environmentVariables: [
            {
              name: 'DB_CONNECTION_STRING'
              secureValue: dbConnectionString
            }
            {
              name: 'STORAGE_CONNECTION_STRING'
              secureValue: storageConnectionString
            }
            {
              name: 'OCPP_16_PORT'
              value: '8092'
            }
            {
              name: 'OCPP_201_SP0_PORT'
              value: '8081'
            }
            {
              name: 'OCPP_201_SP1_PORT'
              value: '8082'
            }
          ]
        }
      }
    ]
    osType: 'Linux'
    restartPolicy: 'Always'
    ipAddress: {
      type: 'Public'
      ports: [
        { port: 8081, protocol: 'TCP' }
        { port: 8082, protocol: 'TCP' }
        { port: 8092, protocol: 'TCP' }
      ]
      dnsNameLabel: '${environmentName}-citrineos'
    }
  }
}

// Hasura GraphQL Container
resource hasura 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: 'aci-${environmentName}-hasura'
  location: location
  properties: {
    containers: [
      {
        name: 'hasura'
        properties: {
          image: 'hasura/graphql-engine:v2.40.3'
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 2
            }
          }
          ports: [
            { port: 8080, protocol: 'TCP' }
          ]
          environmentVariables: [
            {
              name: 'HASURA_GRAPHQL_DATABASE_URL'
              secureValue: dbConnectionString
            }
            {
              name: 'HASURA_GRAPHQL_ENABLE_CONSOLE'
              value: 'true'
            }
            {
              name: 'HASURA_GRAPHQL_ADMIN_SECRET'
              secureValue: 'CitrineOS!${uniqueString(resourceGroup().id)}'
            }
          ]
        }
      }
    ]
    osType: 'Linux'
    restartPolicy: 'Always'
    ipAddress: {
      type: 'Public'
      ports: [
        { port: 8080, protocol: 'TCP' }
      ]
      dnsNameLabel: '${environmentName}-hasura'
    }
  }
}

output containerIPs array = [
  citrineos.properties.ipAddress.ip
  hasura.properties.ipAddress.ip
]
output citrineosFQDN string = citrineos.properties.ipAddress.fqdn
output hasuraFQDN string = hasura.properties.ipAddress.fqdn
```

### 5. Application Gateway Module

```bicep
// modules/appgateway.bicep
param location string
param environmentName string
param backendAddresses array

// Virtual Network for App Gateway
resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: 'vnet-${environmentName}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'AppGatewaySubnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
        }
      }
    ]
  }
}

// Public IP for App Gateway
resource publicIP 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: 'pip-${environmentName}-appgw'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: '${environmentName}-ocpp'
    }
  }
}

// Application Gateway
resource appGateway 'Microsoft.Network/applicationGateways@2023-04-01' = {
  name: 'appgw-${environmentName}'
  location: location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGatewayFrontendIP'
        properties: {
          publicIPAddress: {
            id: publicIP.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port_443'
        properties: {
          port: 443
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'ocpp16Pool'
        properties: {
          backendAddresses: [
            {
              ipAddress: backendAddresses[0]
            }
          ]
        }
      }
      {
        name: 'ocpp201sp0Pool'
        properties: {
          backendAddresses: [
            {
              ipAddress: backendAddresses[0]
            }
          ]
        }
      }
      {
        name: 'hasuraPool'
        properties: {
          backendAddresses: [
            {
              ipAddress: backendAddresses[1]
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'ocppHttpSettings'
        properties: {
          port: 8092
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 300
        }
      }
      {
        name: 'hasuraHttpSettings'
        properties: {
          port: 8080
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
        }
      }
    ]
    httpListeners: [
      {
        name: 'ocpp16Listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', 'appgw-${environmentName}', 'appGatewayFrontendIP')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', 'appgw-${environmentName}', 'port_443')
          }
          protocol: 'Https'
          requireServerNameIndication: false
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'ocpp16Rule'
        properties: {
          ruleType: 'PathBasedRouting'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', 'appgw-${environmentName}', 'ocpp16Listener')
          }
          urlPathMap: {
            id: resourceId('Microsoft.Network/applicationGateways/urlPathMaps', 'appgw-${environmentName}', 'ocppPaths')
          }
        }
      }
    ]
    urlPathMaps: [
      {
        name: 'ocppPaths'
        properties: {
          defaultBackendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', 'appgw-${environmentName}', 'ocpp16Pool')
          }
          defaultBackendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', 'appgw-${environmentName}', 'ocppHttpSettings')
          }
          pathRules: [
            {
              name: 'ocpp16Path'
              properties: {
                paths: [
                  '/ocpp/1.6/*'
                ]
                backendAddressPool: {
                  id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', 'appgw-${environmentName}', 'ocpp16Pool')
                }
                backendHttpSettings: {
                  id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', 'appgw-${environmentName}', 'ocppHttpSettings')
                }
              }
            }
            {
              name: 'ocpp201Path'
              properties: {
                paths: [
                  '/ocpp/2.0.1/*'
                ]
                backendAddressPool: {
                  id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', 'appgw-${environmentName}', 'ocpp201sp0Pool')
                }
                backendHttpSettings: {
                  id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', 'appgw-${environmentName}', 'ocppHttpSettings')
                }
              }
            }
          ]
        }
      }
    ]
  }
}

output appGatewayFQDN string = publicIP.properties.dnsSettings.fqdn
output appGatewayPublicIP string = publicIP.properties.ipAddress
```

## Deployment Steps

### 1. Prerequisites
```bash
# Install Azure CLI
brew install azure-cli

# Login to Azure
az login

# Set subscription
az account set --subscription "YOUR_SUBSCRIPTION_ID"

# Install Bicep
az bicep install
```

### 2. Deploy Infrastructure
```bash
# Navigate to bicep directory
cd ./azure-infra

# Create deployment
az deployment sub create \
  --location eastus \
  --template-file main.bicep \
  --parameters environmentName=citrineos location=eastus
```

### 3. Build and Push Container Images
```bash
# Create Azure Container Registry
az acr create \
  --resource-group rg-citrineos-eastus \
  --name acrcitrineosregistry \
  --sku Basic

# Build CitrineOS image
cd .
az acr build \
  --registry acrcitrineosregistry \
  --image citrineos/core:latest \
  --file local.Dockerfile \
  .
```

### 4. Configure SSL/TLS Certificates
```bash
# Option 1: Use Let's Encrypt with certbot
# Option 2: Use Azure Key Vault certificates
# Option 3: Use managed certificates (if using Azure Front Door)

az keyvault certificate import \
  --vault-name kv-citrineos \
  --name ocpp-cert \
  --file /path/to/certificate.pfx
```

### 5. Update DNS Records
Point your custom domain to the Application Gateway public IP:
```bash
# Get App Gateway IP
az network public-ip show \
  --resource-group rg-citrineos-eastus \
  --name pip-citrineos-appgw \
  --query ipAddress
```

## Terraform Alternative

If you prefer Terraform:

```hcl
# main.tf
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "citrineos" {
  name     = "rg-citrineos-${var.environment}"
  location = var.location
}

resource "azurerm_postgresql_flexible_server" "citrineos" {
  name                   = "psql-citrineos-${var.environment}"
  resource_group_name    = azurerm_resource_group.citrineos.name
  location              = azurerm_resource_group.citrineos.location
  version               = "14"
  administrator_login    = "citrineos_admin"
  administrator_password = var.db_password
  
  sku_name   = "B_Standard_B2s"
  storage_mb = 131072
}

# ... more resources
```

## Monitoring & Observability

### Application Insights
```bicep
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${environmentName}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}
```

### Log Analytics
```bicep
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-${environmentName}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}
```

## Security Considerations

1. **Network Security Groups**: Restrict inbound traffic
2. **Key Vault**: Store all secrets and certificates
3. **Managed Identities**: Use for service-to-service authentication
4. **Private Endpoints**: For database and storage (production)
5. **WAF Rules**: Enable on Application Gateway
6. **DDoS Protection**: Consider for production

## Cost Management

### Budget Alerts
```bash
az consumption budget create \
  --budget-name citrineos-monthly \
  --amount 500 \
  --time-grain Monthly \
  --category Cost
```

### Auto-shutdown (Development)
Enable auto-shutdown for Container Instances during non-business hours.

## Next Steps

1. [ ] Review and customize Bicep templates
2. [ ] Set up Azure DevOps or GitHub Actions for CI/CD
3. [ ] Configure backup and disaster recovery
4. [ ] Set up monitoring and alerting
5. [ ] Plan capacity and scaling strategy
6. [ ] Document runbooks for operations team

## Resources

- Azure Bicep Documentation: https://learn.microsoft.com/azure/azure-resource-manager/bicep/
- Azure Container Instances: https://azure.microsoft.com/services/container-instances/
- Azure Application Gateway: https://azure.microsoft.com/services/application-gateway/
- Cost Calculator: https://azure.microsoft.com/pricing/calculator/

---

**Ready to Deploy?** Contact your Azure administrator or DevOps team to review and execute deployment.
