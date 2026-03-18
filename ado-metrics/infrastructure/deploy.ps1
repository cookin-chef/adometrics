<#
.SYNOPSIS
    Deploy Azure Monitor infrastructure for ADO Metrics Monitoring.
.DESCRIPTION
    Deploys a Log Analytics workspace, action groups, and alert rules
    to Azure using Bicep templates. Captures the workspace shared key
    and outputs configuration instructions.
.PARAMETER ResourceGroupName
    Name of the Azure resource group to deploy into.
.PARAMETER Location
    Azure region (e.g. "eastus", "westeurope").
.PARAMETER DevOpsEmail
    Email address for alert notifications.
.PARAMETER TeamsWebhookUrl
    Optional Microsoft Teams incoming webhook URL for alert notifications.
.PARAMETER WorkspaceName
    Name for the Log Analytics workspace (default: law-ado-metrics).
.PARAMETER Environment
    Environment tag value (default: Production).
.PARAMETER WhatIf
    Preview deployment without making any changes.
.EXAMPLE
    .\deploy.ps1 -ResourceGroupName "rg-ado-metrics" -Location "eastus" -DevOpsEmail "devops@company.com"
    .\deploy.ps1 -ResourceGroupName "rg-ado-metrics" -Location "eastus" -DevOpsEmail "devops@company.com" -TeamsWebhookUrl "https://..." -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$DevOpsEmail,

    [Parameter(Mandatory = $false)]
    [string]$TeamsWebhookUrl = '',

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceName = 'law-ado-metrics',

    [Parameter(Mandatory = $false)]
    [string]$Environment = 'Production',

    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot

#region Helper Functions

function Write-Step {
    param([string]$Message, [int]$Step = 0, [int]$Total = 0)
    $prefix = if ($Step -gt 0) { "[$Step/$Total]" } else { "[INFO]" }
    Write-Host "$prefix $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

#endregion

#region Pre-flight Checks

Write-Host ""
Write-Host "============================================================"
Write-Host " ADO Metrics Monitoring - Azure Infrastructure Deployment"
Write-Host "============================================================"
Write-Host "  Resource Group : $ResourceGroupName"
Write-Host "  Location       : $Location"
Write-Host "  Workspace      : $WorkspaceName"
Write-Host "  Email          : $DevOpsEmail"
Write-Host "  Teams Webhook  : $(if ($TeamsWebhookUrl) { 'Provided' } else { 'Not provided' })"
Write-Host "  Environment    : $Environment"
Write-Host "  WhatIf Mode    : $($WhatIf.IsPresent)"
Write-Host "============================================================"
Write-Host ""

# Step 1: Verify Azure CLI is installed
Write-Step "Checking Azure CLI installation..." -Step 1 -Total 6
try {
    $azVersion = az version --output json 2>&1 | ConvertFrom-Json
    Write-Success "Azure CLI $($azVersion.'azure-cli') found"
}
catch {
    Write-Fail "Azure CLI not found or not in PATH. Install from https://docs.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

# Step 2: Verify Azure login
Write-Step "Checking Azure login..." -Step 2 -Total 6
try {
    $account = az account show --output json 2>&1 | ConvertFrom-Json
    Write-Success "Logged in as: $($account.user.name) | Subscription: $($account.name) ($($account.id))"
}
catch {
    Write-Fail "Not logged in to Azure. Run 'az login' first."
    exit 1
}

if ($WhatIf) {
    Write-Host ""
    Write-Host "[WHATIF] WhatIf mode enabled - previewing deployments without applying changes." -ForegroundColor Yellow
}

#endregion

#region Deploy Resources

# Step 3: Create or verify resource group
Write-Step "Creating resource group '$ResourceGroupName'..." -Step 3 -Total 6
if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Create/verify resource group")) {
    $rgResult = az group create `
        --name     $ResourceGroupName `
        --location $Location `
        --output   json 2>&1 | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to create resource group. Exit code: $LASTEXITCODE"
        exit 1
    }
    Write-Success "Resource group '$ResourceGroupName' ready (state: $($rgResult.properties.provisioningState))"
}

# Step 4: Deploy Log Analytics workspace
Write-Step "Deploying Log Analytics workspace '$WorkspaceName'..." -Step 4 -Total 6
$workspaceBicep = Join-Path $scriptDir 'log-analytics-workspace.bicep'

if (-not (Test-Path $workspaceBicep)) {
    Write-Fail "Bicep template not found: $workspaceBicep"
    exit 1
}

if ($PSCmdlet.ShouldProcess($workspaceBicep, "Deploy Log Analytics workspace")) {
    $whatIfFlag = if ($WhatIf) { '--what-if' } else { '' }

    $workspaceDeployArgs = @(
        'deployment', 'group', 'create'
        '--resource-group', $ResourceGroupName
        '--template-file',  $workspaceBicep
        '--parameters',     "workspaceName=$WorkspaceName"
        '--parameters',     "location=$Location"
        '--parameters',     "environment=$Environment"
        '--output',         'json'
    )
    if ($WhatIf) { $workspaceDeployArgs += '--what-if' }

    $workspaceDeployResult = az @workspaceDeployArgs 2>&1 | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0 -and -not $WhatIf) {
        Write-Fail "Log Analytics workspace deployment failed."
        Write-Host $workspaceDeployResult
        exit 1
    }

    if (-not $WhatIf) {
        $workspaceResourceId = $workspaceDeployResult.properties.outputs.workspaceResourceId.value
        $workspaceCustomerId = $workspaceDeployResult.properties.outputs.workspaceId.value
        Write-Success "Log Analytics workspace deployed. ID: $workspaceCustomerId"
    }
    else {
        Write-Host "[WHATIF] Would deploy Log Analytics workspace '$WorkspaceName'" -ForegroundColor Yellow
    }
}

# Step 5: Deploy action groups
Write-Step "Deploying action groups..." -Step 5 -Total 6
$actionGroupsBicep = Join-Path $scriptDir 'action-groups.bicep'

if (-not (Test-Path $actionGroupsBicep)) {
    Write-Fail "Bicep template not found: $actionGroupsBicep"
    exit 1
}

if ($PSCmdlet.ShouldProcess($actionGroupsBicep, "Deploy action groups")) {
    $actionGroupDeployArgs = @(
        'deployment', 'group', 'create'
        '--resource-group', $ResourceGroupName
        '--template-file',  $actionGroupsBicep
        '--parameters',     "devOpsEmail=$DevOpsEmail"
        '--output',         'json'
    )

    if ($TeamsWebhookUrl) {
        $actionGroupDeployArgs += @('--parameters', "teamsWebhookUrl=$TeamsWebhookUrl")
    }
    if ($WhatIf) { $actionGroupDeployArgs += '--what-if' }

    $agDeployResult = az @actionGroupDeployArgs 2>&1 | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0 -and -not $WhatIf) {
        Write-Fail "Action groups deployment failed."
        Write-Host $agDeployResult
        exit 1
    }

    if (-not $WhatIf) {
        $criticalActionGroupId = $agDeployResult.properties.outputs.criticalActionGroupId.value
        Write-Success "Action groups deployed. Critical AG: $criticalActionGroupId"
    }
    else {
        Write-Host "[WHATIF] Would deploy action groups" -ForegroundColor Yellow
        $criticalActionGroupId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example/providers/Microsoft.Insights/actionGroups/ag-ado-metrics-critical'
    }
}

# Step 6: Deploy alert rules
Write-Step "Deploying alert rules..." -Step 6 -Total 6
$alertRulesBicep = Join-Path $scriptDir 'alert-rules.bicep'

if (-not (Test-Path $alertRulesBicep)) {
    Write-Fail "Bicep template not found: $alertRulesBicep"
    exit 1
}

if ($PSCmdlet.ShouldProcess($alertRulesBicep, "Deploy alert rules")) {
    $alertRulesDeployArgs = @(
        'deployment', 'group', 'create'
        '--resource-group', $ResourceGroupName
        '--template-file',  $alertRulesBicep
        '--parameters',     "workspaceName=$WorkspaceName"
        '--parameters',     "actionGroupId=$criticalActionGroupId"
        '--parameters',     "location=$Location"
        '--output',         'json'
    )
    if ($WhatIf) { $alertRulesDeployArgs += '--what-if' }

    $alertRulesResult = az @alertRulesDeployArgs 2>&1 | ConvertFrom-Json

    if ($LASTEXITCODE -ne 0 -and -not $WhatIf) {
        Write-Fail "Alert rules deployment failed."
        Write-Host $alertRulesResult
        exit 1
    }

    if (-not $WhatIf) {
        Write-Success "Alert rules deployed successfully."
    }
    else {
        Write-Host "[WHATIF] Would deploy 4 alert rules" -ForegroundColor Yellow
    }
}

if ($WhatIf) {
    Write-Host ""
    Write-Host "WhatIf complete. No resources were deployed." -ForegroundColor Yellow
    exit 0
}

#endregion

#region Retrieve Credentials

Write-Host ""
Write-Host "Retrieving Log Analytics shared keys..."

$keysJson = az monitor log-analytics workspace get-shared-keys `
    --resource-group $ResourceGroupName `
    --workspace-name $WorkspaceName `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not retrieve shared keys automatically. Retrieve manually from Azure Portal."
    $sharedKey = '<retrieve-from-azure-portal>'
}
else {
    $keys      = $keysJson | ConvertFrom-Json
    $sharedKey = $keys.primarySharedKey
    Write-Success "Shared key retrieved successfully."
}

#endregion

#region Output Credentials

$credentialsContent = @"
# ADO Metrics Monitoring - Deployment Credentials
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC' -AsUTC)
# IMPORTANT: Keep this file secure. Do NOT commit to source control.

LOG_ANALYTICS_WORKSPACE_ID=$workspaceCustomerId
LOG_ANALYTICS_SHARED_KEY=$sharedKey

# Azure DevOps Variable Group Configuration
# Add these to the 'ado-metrics-config' variable group in Azure DevOps:
# - ADO_PAT            = <your-personal-access-token>  (secret)
# - ENABLE_METRICS_PUSH = true
# - LOG_ANALYTICS_WORKSPACE_ID = $workspaceCustomerId
# - LOG_ANALYTICS_SHARED_KEY   = $sharedKey  (secret)
"@

$credentialsPath = Join-Path $scriptDir 'deployment-credentials.txt'
$credentialsContent | Set-Content -Path $credentialsPath -Encoding UTF8

#endregion

#region Summary

Write-Host ""
Write-Host "============================================================"
Write-Host " Deployment Complete!"
Write-Host "============================================================"
Write-Host ""
Write-Host "  Log Analytics Workspace ID : $workspaceCustomerId"
Write-Host "  Shared Key (Primary)       : $($sharedKey.Substring(0, [Math]::Min(12, $sharedKey.Length)))... (see deployment-credentials.txt)"
Write-Host ""
Write-Host "Credentials saved to: $credentialsPath"
Write-Host ""
Write-Host "Next Steps:"
Write-Host "  1. Open Azure DevOps > Pipelines > Library"
Write-Host "  2. Edit the 'ado-metrics-config' variable group"
Write-Host "  3. Add variable: ENABLE_METRICS_PUSH = true"
Write-Host "  4. Add secret variable: LOG_ANALYTICS_WORKSPACE_ID = $workspaceCustomerId"
Write-Host "  5. Add secret variable: LOG_ANALYTICS_SHARED_KEY = <value from deployment-credentials.txt>"
Write-Host "  6. Run the agent-pool-health-pipeline to verify metrics are flowing"
Write-Host "  7. Wait 15 minutes and query Log Analytics:"
Write-Host "       ADOOperationalMetrics_CL | take 10"
Write-Host ""
Write-Host "Grafana Setup (optional):"
Write-Host "  1. Install Azure Monitor Data Source plugin"
Write-Host "  2. Configure connection to workspace: $workspaceCustomerId"
Write-Host "  3. Import dashboard from: dashboards/grafana/agent-pool-health-dashboard.json"
Write-Host "============================================================"

#endregion
