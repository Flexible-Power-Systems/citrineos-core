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

@description('CitrineOS OCPI container image (from ACR)')
param ocpiImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

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

// Use a unique suffix to avoid conflicts with soft-deleted vaults
// Changed from v3 to v4 to get a fresh vault name; enablePurgeProtection set to true
var keyVaultNameGenerated = 'kv${environmentName}${substring(uniqueString(resourceGroup().id, 'v4'), 0, 8)}'
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
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true  // Cannot be disabled once enabled - set to true for consistency
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

// Enable required PostgreSQL extensions:
// - pgcrypto: required by Hasura
// - postgis: required for geometry/location data types
// - citext: required for case-insensitive text columns
resource postgresExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2022-12-01' = if (empty(existingPostgresServer)) {
  parent: postgres
  name: 'azure.extensions'
  properties: {
    value: 'pgcrypto,postgis,citext'
    source: 'user-override'
  }
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
// 10b. RABBITMQ CONTAINER APP (Message Broker)
// ============================================================================

resource rabbitmqApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'ca-${environmentName}-rabbitmq'
  location: location
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: false
        targetPort: 5672
        transport: 'tcp'
        exposedPort: 5672
      }
    }
    template: {
      containers: [
        {
          name: 'rabbitmq'
          image: 'rabbitmq:3-management'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'RABBITMQ_DEFAULT_USER'
              value: 'guest'
            }
            {
              name: 'RABBITMQ_DEFAULT_PASS'
              value: 'guest'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  dependsOn: [
    hasuraApp
  ]
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
        targetPort: 8081  // WebSocket port (security profile 0) - OCPP chargers connect here
        transport: 'auto'  // Required for WebSocket upgrade support
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
          // CitrineOS requires BOOTSTRAP_CITRINEOS_* prefixed env vars (see 00_Base/src/config/defineConfig.ts)
          env: usePlaceholderImage ? [] : [
            {
              name: 'APP_NAME'
              value: 'all'  // EventGroup: all, router, modules, certificates, etc.
            }
            {
              name: 'APP_ENV'
              value: 'docker'
            }
            {
              name: 'NODE_ENV'
              value: 'production'
            }
            {
              name: 'BOOTSTRAP_CITRINEOS_DATABASE_HOST'
              value: dbServer
            }
            {
              name: 'BOOTSTRAP_CITRINEOS_DATABASE_PORT'
              value: '5432'
            }
            {
              name: 'BOOTSTRAP_CITRINEOS_DATABASE_USERNAME'
              value: 'citrineos_admin'
            }
            {
              name: 'BOOTSTRAP_CITRINEOS_DATABASE_PASSWORD'
              secretRef: 'db-password'
            }
            {
              name: 'BOOTSTRAP_CITRINEOS_DATABASE_NAME'
              value: 'citrineos'
            }
            {
              name: 'BOOTSTRAP_CITRINEOS_DATABASE_SSL_REQUIRE'
              value: 'true'
            }
            {
              name: 'STORAGE_CONNECTION_STRING'
              secretRef: 'storage-connection'
            }
            {
              // Override AMQP URL to point to RabbitMQ container app (see README.md for env var naming)
              name: 'CITRINEOS_util_messageBroker_amqp_url'
              value: 'amqp://guest:guest@ca-${environmentName}-rabbitmq:5672'
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
    rabbitmqApp
  ]
}

// ============================================================================
// 12. CITRINEOS OCPI CONTAINER APP
// ============================================================================

resource ocpiApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'ca-${environmentName}-citrineos-ocpi'
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
      registries: usePlaceholderImage ? [] : [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      ingress: {
        external: true
        targetPort: 8085
        transport: 'http'
        allowInsecure: false
      }
      secrets: usePlaceholderImage ? [] : [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'citrineos-ocpi'
          image: ocpiImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: usePlaceholderImage ? [] : [
            {
              name: 'APP_NAME'
              value: 'all'
            }
            {
              name: 'APP_ENV'
              value: 'docker'
            }
            {
              name: 'DB_HOST'
              value: dbServer
            }
            {
              name: 'DB_PORT'
              value: '5432'
            }
            {
              name: 'DB_NAME'
              value: 'citrineos'
            }
            {
              name: 'DB_USER'
              value: 'citrineos_admin'
            }
            {
              name: 'DB_PASS'
              value: postgresPassword
            }
            {
              name: 'DB_SSL'
              value: 'true'
            }
            {
              name: 'GRAPHQL_ENDPOINT'
              value: 'https://${hasuraApp.properties.configuration.ingress.fqdn}/v1/graphql'
            }
            {
              name: 'GRAPHQL_HEADERS'
              value: '{"x-hasura-admin-secret":"${hasuraAdminSecret}"}'
            }
            {
              name: 'AMQP_URL'
              value: 'amqp://guest:guest@ca-${environmentName}-rabbitmq.internal.${containerAppEnv.properties.defaultDomain}:5672'
            }
            {
              name: 'AMQP_EXCHANGE'
              value: 'ocpi'
            }
            {
              name: 'COMMANDS_OCPP_REQUESTSTARTTRANSACTION'
              value: 'http://ca-${environmentName}-citrineos.internal.${containerAppEnv.properties.defaultDomain}:8080/data/monitoring/requeststarttransaction'
            }
            {
              name: 'COMMANDS_OCPP_REQUESTSTOPTRANSACTION'
              value: 'http://ca-${environmentName}-citrineos.internal.${containerAppEnv.properties.defaultDomain}:8080/data/monitoring/requeststoptransaction'
            }
            {
              name: 'LOG_LEVEL'
              value: '2'
            }
          ]
          probes: [
            {
              type: 'Startup'
              httpGet: {
                path: '/ocpi/health'
                port: 8085
              }
              initialDelaySeconds: 10
              periodSeconds: 10
              failureThreshold: 30
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
  dependsOn: [
    hasuraApp
    rabbitmqApp
    citrineoApp
  ]
}

// ============================================================================
// 13. OPERATOR UI CONTAINER APP
// ============================================================================

resource operatorUiApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: 'ca-${environmentName}-operator-ui'
  location: location
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 3000
        transport: 'http'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'operator-ui'
          image: 'citrineos/operator-ui:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'VITE_HASURA_URL'
              value: 'https://${hasuraApp.properties.configuration.ingress.fqdn}/v1/graphql'
            }
            {
              name: 'VITE_HASURA_WS_URL'
              value: 'wss://${hasuraApp.properties.configuration.ingress.fqdn}/v1/graphql'
            }
            {
              name: 'VITE_HASURA_ADMIN_SECRET'
              value: hasuraAdminSecret
            }
            {
              name: 'VITE_CITRINEOS_URL'
              value: 'https://${citrineoApp.properties.configuration.ingress.fqdn}'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
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
output ocpiFqdn string = ocpiApp.properties.configuration.ingress.fqdn
output operatorUiFqdn string = operatorUiApp.properties.configuration.ingress.fqdn
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
