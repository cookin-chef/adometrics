@description('Name of the Log Analytics workspace')
param workspaceName string = 'law-ado-metrics'

@description('Azure region for the workspace')
param location string = resourceGroup().location

@description('Pricing SKU for the workspace')
@allowed([
  'PerGB2018'
  'Free'
  'Standalone'
  'PerNode'
  'Standard'
  'Premium'
])
param sku string = 'PerGB2018'

@description('Data retention in days (31-730 for PerGB2018)')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('Deployment environment tag')
param environment string = 'Production'

@description('Cost center tag for billing allocation')
param costCenter string = 'DevOps'

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: 1  // Limit daily ingestion to 1 GB to control costs
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    features: {
      disableLocalAuth: false
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
  tags: {
    Environment: environment
    CostCenter: costCenter
    Purpose: 'ADO Metrics Monitoring'
    ManagedBy: 'Bicep IaC'
  }
}

// Outputs consumed by downstream Bicep deployments and deploy.ps1
output workspaceId string = logAnalyticsWorkspace.properties.customerId
output workspaceResourceId string = logAnalyticsWorkspace.id
output workspaceName string = logAnalyticsWorkspace.name
