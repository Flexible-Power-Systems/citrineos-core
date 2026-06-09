// Development Environment
// Resource Group: fps_server_dev (to be created)
// Purpose: Active development and integration testing
// NOTE: Uses container-apps-deploy.bicep (Container Apps, not ACI)
// minReplicas for CitrineOS is set to 1 in the template — do not override to 0
// as this breaks OCPP WebSocket connections (charger emulator reconnect fails).

using './container-apps-deploy.bicep'

param environmentName = 'dev'
param location = 'uksouth'

// Database Configuration
param postgresPassword = '' // Will be prompted or from Key Vault
param hasuraAdminSecret = '' // Retrieve from Key Vault in production workflow

// Shared Resources
// In dev, you might share PostgreSQL with other services
param existingPostgresServer = '' // Optional: share database server

// Resource Sizing (Development)
// - PostgreSQL: General Purpose 2 vCores (~$120/month) with HA
// - Container Instances: 2 CPU, 4GB RAM
// - ACR: Standard tier (~$20/month) for image scanning
// Total: ~$200/month
