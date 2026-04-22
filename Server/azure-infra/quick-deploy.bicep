// Quick Deploy: CitrineOS to Azure (Minimal Setup)
// Deploy to existing resource group for testing

@description('Environment name (e.g., dev, test)')
param environmentName string = 'dev'

@description('Location for resources')
param location string = resourceGroup().location

@description('Existing PostgreSQL server name (leave empty to create new)')
param existingPostgresServer string = ''

@description('PostgreSQL admin password (if creating new server)')
@secure()
param postgresPassword string

@description('Hasura admin secret')
@secure()
param hasuraAdminSecret string = 'CitrineOS!${uniqueString(resourceGroup().id)}'

// ============================================================================
// 1. CONTAINER REGISTRY (for your images)
// ============================================================================

resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: 'acr${environmentName}${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// ============================================================================
// 2. POSTGRESQL (if not using existing)
// ============================================================================

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2022-12-01' = if (empty(existingPostgresServer)) {
  name: 'psql-${environmentName}-citrineos'
  location: location
  sku: {
    name: 'Standard_B2s'
    tier: 'Burstable'
  }
  properties: {
    version: '14'
    administratorLogin: 'citrineos_admin'
    administratorLoginPassword: postgresPassword
    storage: {
      storageSizeGB: 32
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

resource postgresFirewall 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2022-12-01' = if (empty(existingPostgresServer)) {
  parent: postgres
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource postgresDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2022-12-01' = if (empty(existingPostgresServer)) {
  parent: postgres
  name: 'citrineos'
}

// ============================================================================
// 3. STORAGE ACCOUNT (replaces MinIO)
// ============================================================================

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
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

// ============================================================================
// 4. LOG ANALYTICS (for monitoring)
// ============================================================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-${environmentName}-citrineos'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ============================================================================
// 5. HASURA CONTAINER INSTANCE
// ============================================================================

var dbServer = empty(existingPostgresServer) ? postgres.properties.fullyQualifiedDomainName : existingPostgresServer
var dbConnectionString = 'postgresql://citrineos_admin:${postgresPassword}@${dbServer}:5432/citrineos?sslmode=require'

resource hasuraContainer 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
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
              secureValue: hasuraAdminSecret
            }
            {
              name: 'HASURA_GRAPHQL_ENABLED_LOG_TYPES'
              value: 'startup, http-log, webhook-log, websocket-log, query-log'
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
      dnsNameLabel: '${environmentName}-citrineos-hasura-${uniqueString(resourceGroup().id)}'
    }
    diagnostics: {
      logAnalytics: {
        workspaceId: logAnalytics.properties.customerId
        workspaceKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// ============================================================================
// 6. CITRINEOS CONTAINER INSTANCE
// ============================================================================

resource citrineos 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: 'aci-${environmentName}-citrineos'
  location: location
  properties: {
    containers: [
      {
        name: 'citrineos-core'
        properties: {
          // Initially use your custom-built image from ACR
          // Will update after first docker push
          image: 'citrineos/citrineos:latest' // Placeholder - will override during deployment
          resources: {
            requests: {
              cpu: 2
              memoryInGB: 4
            }
          }
          ports: [
            { port: 8081, protocol: 'TCP' } // OCPP 2.0.1 SP0
            { port: 8082, protocol: 'TCP' } // OCPP 2.0.1 SP1
            { port: 8092, protocol: 'TCP' } // OCPP 1.6
          ]
          environmentVariables: [
            {
              name: 'DB_HOST'
              value: dbServer
            }
            {
              name: 'DB_PORT'
              value: '5432'
            }
            {
              name: 'DB_USER'
              value: 'citrineos_admin'
            }
            {
              name: 'DB_PASSWORD'
              secureValue: postgresPassword
            }
            {
              name: 'DB_NAME'
              value: 'citrineos'
            }
            {
              name: 'STORAGE_CONNECTION_STRING'
              secureValue: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
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
      dnsNameLabel: '${environmentName}-citrineos-${uniqueString(resourceGroup().id)}'
    }
    diagnostics: {
      logAnalytics: {
        workspaceId: logAnalytics.properties.customerId
        workspaceKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
  dependsOn: [
    hasuraContainer // Ensure Hasura starts first
  ]
}

// ============================================================================
// OUTPUTS
// ============================================================================

output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output hasuraUrl string = 'http://${hasuraContainer.properties.ipAddress.fqdn}:8080'
output citrineosFqdn string = citrineos.properties.ipAddress.fqdn
output ocpp16Endpoint string = 'ws://${citrineos.properties.ipAddress.fqdn}:8092/'
output ocpp201sp0Endpoint string = 'ws://${citrineos.properties.ipAddress.fqdn}:8081/'
output ocpp201sp1Endpoint string = 'ws://${citrineos.properties.ipAddress.fqdn}:8082/'
output postgresServer string = dbServer
output storageAccountName string = storage.name
output resourceGroupName string = resourceGroup().name

output nextSteps string = '''
🎉 Deployment Complete! Next steps:

1. Build and push CitrineOS image:
   cd .
   az acr build --registry ${acr.name} --image citrineos/core:v1.0.0 --file local.Dockerfile .

2. Update container to use ACR image:
   az container create --resource-group ${resourceGroup().name} --file quick-deploy.bicep --parameters existingPostgresServer=${dbServer}

3. Configure your charger:
   OCPP 1.6: ws://${citrineos.properties.ipAddress.fqdn}:8092/YOUR_CHARGER_ID
   OCPP 2.0.1: ws://${citrineos.properties.ipAddress.fqdn}:8081/YOUR_CHARGER_ID

4. Check logs:
   az container logs --resource-group ${resourceGroup().name} --name aci-${environmentName}-citrineos
'''
