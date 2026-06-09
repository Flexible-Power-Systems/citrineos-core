// Production Environment
// Resource Group: fps_server_prod (to be created)
// Purpose: Live production workload

using './quick-deploy.bicep'

param environmentName = 'prod'
param location = 'eastus'

// Database Configuration
param postgresPassword = '' // MUST be retrieved from Key Vault
param hasuraAdminSecret = '' // MUST be retrieved from Key Vault

// Production Configuration
param existingPostgresServer = '' // Dedicated PostgreSQL with HA

// Resource Sizing (Production)
// - PostgreSQL: General Purpose 4-8 vCores with HA, geo-redundant backup
// - Container Instances: 4 CPU, 8GB RAM with auto-restart
// - ACR: Premium tier with geo-replication
// - Application Gateway: WAF_v2 with SSL, DDoS protection
// - Private Endpoints for security
// - Application Insights for monitoring
// Total: ~$800-1200/month

// Additional Production Requirements:
// - Backup retention: 35 days
// - Geo-redundant backups enabled
// - Private networking (VNet injection)
// - Managed identities (no passwords)
// - Azure Monitor alerts configured
// - Log Analytics retention: 90 days
