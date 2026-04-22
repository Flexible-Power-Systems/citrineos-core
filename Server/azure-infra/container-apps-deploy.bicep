// CitrineOS Azure Container Apps Deployment
// Uses Azure Container Apps with Key Vault for secrets management
// Managed Identity provides secure, credential-free access to secrets

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

@description('Existing Key Vault name (leave empty to create new)')
param existingKeyVaultName string = ''

// ============================================================================
// 1. USER-ASSIGNED MANAGED IDENTITY
// ============================================================================

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${environmentName}-citrineos'
  location: location
}

// ============================================================================
// 2. KEY VAULT
// ============================================================================

var keyVaultNameGenerated = 'kv-${environmentName}-${uniqueString(resourceGroup().id)}'
var keyVaultNameToUse = empty(existingKeyVaultName) ? keyVaultNameGenerated : existingKeyVaultName

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (empty(existingKeyVaultName)) {
  name: keyVaultNameGenerated
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true // Use RBAC instead of access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 30
    enablePurgeProtection: false // Set to true for production
    publicNetworkAccess: 'Enabled'
  }
}

// Reference existing Key Vault if provided
resource existingKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(existingKeyVaultName)) {
  name: existingKeyVaultName
}

// Grant managed identity access to Key Vault secrets (for new Key Vault)
resource keyVaultSecretsUserNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (empty(existingKeyVaultName)) {
  name: guid(resourceGroup().id, keyVaultNameGenerated, managedIdentity.id, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Grant managed identity access to existing Key Vault secrets
resource keyVaultSecretsUserExisting 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(existingKeyVaultName)) {
  name: guid(resourceGroup().id, existingKeyVaultName, managedIdentity.id, 'Key Vault Secrets User')
  scope: existingKeyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// 3. KEY VAULT SECRETS
// ============================================================================

resource secretPostgresPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(existingKeyVaultName)) {
  parent: keyVault
  name: 'postgres-password'
  properties: {
    value: postgresPassword
  }
}

resource secretHasuraAdminSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(existingKeyVaultName)) {
  parent: keyVault
  name: 'hasura-admin-secret'
  properties: {
    value: hasuraAdminSecret
  }
}

// Storage connection string will be added after storage account is created

// ============================================================================
// 4. CONTAINER REGISTRY
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
// 5. POSTGRESQL (if not using existing)
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
// 6. STORAGE ACCOUNT (replaces MinIO)
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

// Store storage connection string in Key Vault
resource secretStorageConnection 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (empty(existingKeyVaultName)) {
  parent: keyVault
  name: 'storage-connection-string'
  properties: {
    value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
  }
}

// ============================================================================
// 7. LOG ANALYTICS (for monitoring)
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
// 8. CONTAINER APPS ENVIRONMENT
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
// 9. DATABASE CONNECTION VARIABLES
// ============================================================================

var dbServer = empty(existingPostgresServer) ? postgres.properties.fullyQualifiedDomainName : existingPostgresServer
var dbConnectionString = 'postgresql://citrineos_admin:${postgresPassword}@${dbServer}:5432/citrineos?sslmode=require'

// Key Vault URI for referencing secrets (constructed from name)
var keyVaultUri = 'https://${keyVaultNameToUse}${environment().suffixes.keyvaultDns}/'

// ============================================================================
// 10. HASURA CONTAINER APP
// ============================================================================

resource hasuraApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'ca-${environmentName}-hasura'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
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
          // For Hasura, we construct the connection string (can't easily use Key Vault reference)
          value: dbConnectionString
        }
        {
          name: 'admin-secret'
          identity: managedIdentity.id
          keyVaultUrl: '${keyVaultUri}secrets/hasura-admin-secret'
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
// 11. CITRINEOS CONTAINER APP
// ============================================================================

resource citrineoApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'ca-${environmentName}-citrineos'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
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
          identity: managedIdentity.id
          keyVaultUrl: '${keyVaultUri}secrets/postgres-password'
        }
        {
          name: 'storage-connection'
          identity: managedIdentity.id
          keyVaultUrl: '${keyVaultUri}secrets/storage-connection-string'
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

// Key Vault outputs
output keyVaultName string = keyVaultNameToUse
output keyVaultUri string = keyVaultUri
output managedIdentityId string = managedIdentity.id
output managedIdentityClientId string = managedIdentity.properties.clientId

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

output secretsInfo string = '🔐 Secrets Management (Azure Key Vault)\\n\\nSecrets are stored in Key Vault: ${keyVaultNameToUse}\\n- postgres-password: PostgreSQL admin password\\n- hasura-admin-secret: Hasura GraphQL admin secret\\n- storage-connection-string: Azure Storage connection string\\n\\nContainer Apps access secrets via Managed Identity (no credentials in code).\\nTo view/rotate secrets:\\n  az keyvault secret list --vault-name ${keyVaultNameToUse}\\n  az keyvault secret set --vault-name ${keyVaultNameToUse} --name <secret-name> --value <new-value>'

output nextSteps string = '🎉 Container Apps Deployment Complete!\\n\\n1. Build and push CitrineOS image to ACR:\\n   az acr build --registry ${acr.name} --image citrineos/core:v1.0.0 --file local.Dockerfile ..\\n\\n2. Update the container app to use your image:\\n   az containerapp update --name ca-${environmentName}-citrineos --resource-group ${resourceGroup().name} --image ${acr.properties.loginServer}/citrineos/core:v1.0.0\\n\\n3. Configure your EV charger:\\n   OCPP URL: wss://${citrineoApp.properties.configuration.ingress.fqdn}/YOUR_CHARGER_ID\\n\\n4. Access Hasura Console:\\n   URL: https://${hasuraApp.properties.configuration.ingress.fqdn}/console\\n\\n5. Manage secrets in Key Vault:\\n   az keyvault secret list --vault-name ${keyVaultNameToUse}\\n\\n6. Check logs:\\n   az containerapp logs show --name ca-${environmentName}-citrineos --resource-group ${resourceGroup().name} --follow'
