@description('Name of the existing Log Analytics workspace')
param workspaceName string

@description('Resource ID of the action group to notify on alerts')
param actionGroupId string

@description('Azure region for alert rule resources')
param location string = resourceGroup().location

// Reference the existing Log Analytics workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

// Alert 1: Critical - Agent pool queue wait time >= 15 minutes
resource criticalQueueAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'ado-agentpool-critical'
  location: location
  properties: {
    displayName: 'ADO Agent Pool Critical Queue Time'
    description: 'Fires when any agent pool has jobs waiting >= 15 minutes. Indicates agents are unavailable or overloaded.'
    severity: 1
    enabled: true
    autoMitigate: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [
      logAnalyticsWorkspace.id
    ]
    criteria: {
      allOf: [
        {
          query: '''
ADOOperationalMetrics_CL
| where MetricName_s == "AgentPoolOldestQueued"
| where Value_d >= 15
| summarize MaxQueueTime = max(Value_d) by PoolName_s, bin(TimeGenerated, 5m)
| where MaxQueueTime >= 15
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 2
            minFailingPeriodsToAlert: 2
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
      customProperties: {
        Severity: 'Critical'
        Component: 'ADO Agent Pools'
      }
    }
  }
}

// Alert 2: Warning - Agent pool queue wait time 5-15 minutes
resource warningQueueAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'ado-agentpool-warning'
  location: location
  properties: {
    displayName: 'ADO Agent Pool Warning Queue Time'
    description: 'Fires when any agent pool has jobs waiting 5-15 minutes. Early warning of potential capacity issues.'
    severity: 2
    enabled: true
    autoMitigate: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT10M'
    scopes: [
      logAnalyticsWorkspace.id
    ]
    criteria: {
      allOf: [
        {
          query: '''
ADOOperationalMetrics_CL
| where MetricName_s == "AgentPoolOldestQueued"
| where Value_d >= 5 and Value_d < 15
| summarize MaxQueueTime = max(Value_d) by PoolName_s, bin(TimeGenerated, 5m)
| where MaxQueueTime >= 5 and MaxQueueTime < 15
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 2
            minFailingPeriodsToAlert: 2
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
      customProperties: {
        Severity: 'Warning'
        Component: 'ADO Agent Pools'
      }
    }
  }
}

// Alert 3: Pipeline growth anomaly (daily check)
resource pipelineGrowthAnomalyAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'ado-pipeline-growth-anomaly'
  location: location
  properties: {
    displayName: 'ADO Pipeline Count Anomaly'
    description: 'Detects unusual spikes or drops in the total pipeline count using time-series anomaly detection.'
    severity: 3
    enabled: true
    autoMitigate: true
    evaluationFrequency: 'P1D'
    windowSize: 'P30D'
    scopes: [
      logAnalyticsWorkspace.id
    ]
    criteria: {
      allOf: [
        {
          query: '''
ADOInventoryMetrics_CL
| where MetricName_s == "TotalPipelines"
| make-series PipelineCount=max(Value_d) default=0 on TimeGenerated from ago(30d) to now() step 1d
| extend (AnomalyScore, Trend, ExpectedValue) = series_decompose_anomalies(PipelineCount, 1.5)
| mv-expand PipelineCount, ExpectedValue, AnomalyScore, TimeGenerated
| where AnomalyScore > 0
| project TimeGenerated, PipelineCount=toint(PipelineCount), ExpectedValue=toint(ExpectedValue), AnomalyScore=toint(AnomalyScore)
'''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
      customProperties: {
        Severity: 'Informational'
        Component: 'ADO Pipeline Inventory'
      }
    }
  }
}

// Alert 4: Monitoring heartbeat - no data received in 30 minutes
resource monitoringNoDataAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'ado-monitoring-no-data'
  location: location
  properties: {
    displayName: 'ADO Monitoring - No Data Received'
    description: 'Fires when no operational metrics have been received in the last 30 minutes. Indicates the health check pipeline may be failing.'
    severity: 2
    enabled: true
    autoMitigate: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    scopes: [
      logAnalyticsWorkspace.id
    ]
    criteria: {
      allOf: [
        {
          query: '''
ADOOperationalMetrics_CL
| where TimeGenerated > ago(30m)
| summarize Count = count()
'''
          timeAggregation: 'Count'
          operator: 'LessThan'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 2
            minFailingPeriodsToAlert: 2
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
      customProperties: {
        Severity: 'Warning'
        Component: 'ADO Monitoring Pipeline'
      }
    }
  }
}
