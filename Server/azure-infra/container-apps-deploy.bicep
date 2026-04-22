// CitrineOS Azure Container Apps Deployment
// Uses Azure Container Apps instead of ACI for better scaling and built-in HTTPS

@description('Environment name (e.g., dev, test, prod)')
param environmentName string = 'dev'

@description('Location for resources')
param location string = resourceGroup().location

@description('Existing PostgreSQL server name (leave empty to create new)')
param existingPostgresServer string = ''

@description('PostgreSQL admin password')
@secure()
param postgresPassword string

@description('Hasura admin secret')
@secure()
param hasuraAdminSecret string

@description('CitrineOS container image (from ACR) - use placeholder for initial deployment')
param citrineoImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Use placeholder image (true for initial deployment)')
param usePlaceholderImage bool = true

// ============================================================================
// 1. CONTAINER REGISTRY
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
// 5. CONTAINER APPS ENVIRONMENT
// ============================================================================

resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: 'cae-${environmentName}-citrineos'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    zoneRedundant: false
  }
}

// ============================================================================
// 6. DATABASE CONNECTION VARIABLES
// ============================================================================

var dbServer = empty(existingPostgresServer) ? postgres.properties.fullyQualifiedDomainName : existingPostgresServer
var dbConnectionString = 'postgresql://citrineos_admin:${postgresPassword}@${dbServer}:5432/citrineos?sslmode=require'

// ============================================================================
// 7. HASURA CONTAINER APP
// ============================================================================

resource hasuraApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'ca-${environmentName}-hasura'
  location: location
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
        allowInsecure: false // Force HTTPS
      }
      secrets: [
        {
          name: 'database-url'
          value: dbConnectionString
        }
        {
          name: 'admin-secret'
          value: hasuraAdminSecret
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'hasura'
          image: 'hasura/graphql-engine:v2.40.3'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'HASURA_GRAPHQL_DATABASE_URL'
              secretRef: 'database-url'
            }
            {
              name: 'HASURA_GRAPHQL_ENABLE_CONSOLE'
              value: 'true'
            }
            {
              name: 'HASURA_GRAPHQL_ADMIN_SECRET'
              secretRef: 'admin-secret'
            }
            {
              name: 'HASURA_GRAPHQL_ENABLED_LOG_TYPES'
              value: 'startup, http-log, webhook-log, websocket-log, query-log'
            }
            {
              name: 'HASURA_GRAPHQL_DEV_MODE'
              value: 'true'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 2
      }
    }
  }
}

// ============================================================================
// 8. CITRINEOS CONTAINER APP
// ============================================================================

resource citrineoApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'ca-${environmentName}-citrineos'
  location: location
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      // Only configure ACR registry when using actual CitrineOS image
      registries: usePlaceholderImage ? [] : [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      ingress: {
        external: true
        targetPort: 8080  // Main HTTP port - CitrineOS handles OCPP WebSocket here
        transport: 'http'
        allowInsecure: false
        // Note: Container Apps supports WebSocket connections on the main ingress port
        // Configure CitrineOS to use port 8080 for all OCPP protocols
      }
      secrets: usePlaceholderImage ? [] : [
        {
          name: 'db-password'
          value: postgresPassword
        }
        {
          name: 'storage-connection'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'citrineos-core'
          image: citrineoImage
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          // Only include env vars with secret refs when not using placeholder
          env: usePlaceholderImage ? [] : [
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
              secretRef: 'db-password'
            }
            {
              name: 'DB_NAME'
              value: 'citrineos'
            }
            {
              name: 'STORAGE_CONNECTION_STRING'
              secretRef: 'storage-connection'
            }
            {
              name: 'NODE_ENV'
              value: 'production'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
        rules: [
          {
            name: 'http-scale'
            http: {
              metadata: {
                concurrentRequests: '100'
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [
    hasuraApp
  ]
}

// ============================================================================
// OUTPUTS
// ============================================================================

output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output hasuraUrl string = 'https://${hasuraApp.properties.configuration.ingress.fqdn}'
output citrineosFqdn string = citrineoApp.properties.configuration.ingress.fqdn
output containerAppEnvName string = containerAppEnv.name

// OCPP endpoints (now using secure WebSocket over HTTPS)
output ocppEndpointInfo string = '''
OCPP Endpoints (use wss:// for secure WebSocket):
- Primary: wss://${citrineoApp.properties.configuration.ingress.fqdn}/YOUR_CHARGER_ID

Note: Azure Container Apps provides built-in TLS termination.
Configure your charger to use the secure WebSocket URL above.
'''

output postgresServer string = dbServer
output storageAccountName string = storage.name
output resourceGroupName string = resourceGroup().name

output nextSteps string = '''
🎉 Container Apps Deployment Complete!

1. Build and push CitrineOS image to ACR:
   az acr build --registry ${acrName} --image citrineos/core:v1.0.0 --file local.Dockerfile ..

2. Update the container app to use your image:
   az containerapp update --name ca-${environmentName}-citrineos \
     --resource-group ${resourceGroupName} \
     --image ${acrLoginServer}/citrineos/core:v1.0.0

3. Configure your EV charger:
   OCPP URL: wss://${citrineosFqdn}/YOUR_CHARGER_ID

4. Access Hasura Console:
   URL: ${hasuraUrl}/console

5. Check logs:
   az containerapp logs show --name ca-${environmentName}-citrineos \
     --resource-group ${resourceGroupName} --follow
'''
