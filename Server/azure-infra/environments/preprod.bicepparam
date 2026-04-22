// Pre-Production Environment (Staging)
// Resource Group: fps_server_preprod (to be created)
// Purpose: Production-like testing, final validation before prod

using './quick-deploy.bicep'

param environmentName = 'preprod'
param location = 'eastus'

// Database Configuration
param postgresPassword = '' // Retrieved from Key Vault
param hasuraAdminSecret = '' // Retrieved from Key Vault

// Production-like Configuration
param existingPostgresServer = '' // Typically dedicated PostgreSQL

// Resource Sizing (Production-like)
// - PostgreSQL: General Purpose 4 vCores with HA (~$400/month)
// - Container Instances: 4 CPU, 8GB RAM for realistic load testing
// - ACR: Premium tier for geo-replication
// - Application Gateway: Standard v2 for SSL/WAF
// Total: ~$600/month
