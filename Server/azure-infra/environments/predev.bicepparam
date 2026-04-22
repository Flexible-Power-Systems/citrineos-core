// Pre-Dev Environment (POC/Testing)
// Resource Group: rg-citrine-ev-dev
// Purpose: Initial proof-of-concept and charger testing

using './quick-deploy.bicep'

param environmentName = 'predev'
param location = 'eastus'

// Use existing resource group provided by DevOps
// Deploy with: az deployment group create --resource-group rg-citrine-ev-dev

// Database Configuration
param postgresPassword = '' // Will be prompted during deployment
param hasuraAdminSecret = 'CitrineOS!PreDev2026'

// Optional: Use existing PostgreSQL if DevOps provided one
param existingPostgresServer = '' // Leave empty to create new

// Resource Sizing (Cost-optimized for POC)
// - PostgreSQL: Burstable B2s (~$30/month)
// - Container Instances: 2 CPU, 4GB RAM (~$60/month)  
// - ACR: Basic tier (~$5/month)
// Total: ~$100/month
