@description('Email address for DevOps team alerts')
param devOpsEmail string

@description('Microsoft Teams incoming webhook URL (optional)')
param teamsWebhookUrl string = ''

@description('Azure region for action groups (use global for action groups)')
param location string = 'global'

var hasTeamsWebhook = !empty(teamsWebhookUrl)

// Critical action group - email + Teams for P1 issues
resource criticalActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-ado-metrics-critical'
  location: location
  properties: {
    groupShortName: 'ADOCrit'
    enabled: true
    emailReceivers: [
      {
        name: 'DevOps Team Critical'
        emailAddress: devOpsEmail
        useCommonAlertSchema: true
      }
    ]
    webhookReceivers: hasTeamsWebhook ? [
      {
        name: 'Teams Critical Channel'
        serviceUri: teamsWebhookUrl
        useCommonAlertSchema: true
        useAadAuth: false
      }
    ] : []
    smsReceivers: []
    azureAppPushReceivers: []
    voiceReceivers: []
    logicAppReceivers: []
    azureFunctionReceivers: []
    armRoleReceivers: []
    eventHubReceivers: []
    itsmReceivers: []
    automationRunbookReceivers: []
  }
  tags: {
    Purpose: 'ADO Metrics Monitoring'
    Severity: 'Critical'
  }
}

// Warning action group - email + Teams for P2 issues
resource warningActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-ado-metrics-warning'
  location: location
  properties: {
    groupShortName: 'ADOWarn'
    enabled: true
    emailReceivers: [
      {
        name: 'DevOps Team Warning'
        emailAddress: devOpsEmail
        useCommonAlertSchema: true
      }
    ]
    webhookReceivers: hasTeamsWebhook ? [
      {
        name: 'Teams Warning Channel'
        serviceUri: teamsWebhookUrl
        useCommonAlertSchema: true
        useAadAuth: false
      }
    ] : []
    smsReceivers: []
    azureAppPushReceivers: []
    voiceReceivers: []
    logicAppReceivers: []
    azureFunctionReceivers: []
    armRoleReceivers: []
    eventHubReceivers: []
    itsmReceivers: []
    automationRunbookReceivers: []
  }
  tags: {
    Purpose: 'ADO Metrics Monitoring'
    Severity: 'Warning'
  }
}

// Info action group - Teams only for informational alerts
resource infoActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-ado-metrics-info'
  location: location
  properties: {
    groupShortName: 'ADOInfo'
    enabled: true
    emailReceivers: []
    webhookReceivers: hasTeamsWebhook ? [
      {
        name: 'Teams Info Channel'
        serviceUri: teamsWebhookUrl
        useCommonAlertSchema: true
        useAadAuth: false
      }
    ] : []
    smsReceivers: []
    azureAppPushReceivers: []
    voiceReceivers: []
    logicAppReceivers: []
    azureFunctionReceivers: []
    armRoleReceivers: []
    eventHubReceivers: []
    itsmReceivers: []
    automationRunbookReceivers: []
  }
  tags: {
    Purpose: 'ADO Metrics Monitoring'
    Severity: 'Informational'
  }
}

output criticalActionGroupId string = criticalActionGroup.id
output warningActionGroupId string = warningActionGroup.id
output infoActionGroupId string = infoActionGroup.id
