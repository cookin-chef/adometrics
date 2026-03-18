<#
.SYNOPSIS
    Run Azure DevOps agent pool health checks and generate reports.
.DESCRIPTION
    Collects health metrics from all ADO agent pools, generates JSON and Markdown
    reports, optionally pushes metrics to Azure Monitor Log Analytics, and exits
    with code 1 if any pools are in a Critical state (enabling pipeline gate on failures).
.PARAMETER Organization
    Azure DevOps organization name or URL.
.PARAMETER PAT
    Personal Access Token with Agent Pools (read) scope.
.PARAMETER OutputPath
    Directory where report files will be written (default: ./output).
.EXAMPLE
    .\Run-AgentPoolHealth.ps1 -Organization "myorg" -PAT $env:ADO_PAT
    .\Run-AgentPoolHealth.ps1 -Organization "myorg" -PAT $env:ADO_PAT -OutputPath "C:\reports" -Verbose
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$PAT,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = './output'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Module Imports

$libPath = Join-Path $PSScriptRoot '..\..\lib'

Write-Verbose "Loading modules from: $libPath"

. (Join-Path $libPath 'AdoAuthHelper.ps1')
. (Join-Path $libPath 'AdoHttpHelper.ps1')
. (Join-Path $PSScriptRoot 'Get-AgentPoolMetrics.ps1')

# MetricsHelper is optional - gracefully skip if not present
$metricsHelperPath = Join-Path $libPath 'MetricsHelper.ps1'
$metricsAvailable  = Test-Path $metricsHelperPath
if ($metricsAvailable) {
    . $metricsHelperPath
    Write-Verbose "MetricsHelper loaded"
}
else {
    Write-Verbose "MetricsHelper not found at '$metricsHelperPath' - Azure Monitor push disabled"
}

#endregion

#region Initialization

$enableMetricsPush = ($env:ENABLE_METRICS_PUSH -eq 'true') -and $metricsAvailable

# Normalize organization name (strip URL prefixes if provided)
$orgName = Get-NormalizedOrgName -OrgNameOrUrl $Organization

Write-Host ""
Write-Host "============================================================"
Write-Host " Azure DevOps Agent Pool Health Check"
Write-Host "============================================================"
Write-Host "  Organization : $orgName"
Write-Host "  Output Path  : $OutputPath"
Write-Host "  Metrics Push : $enableMetricsPush"
Write-Host "  Timestamp    : $([DateTime]::UtcNow.ToString('u'))"
Write-Host "============================================================"
Write-Host ""

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    Write-Verbose "Creating output directory: $OutputPath"
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Build authentication headers
$headers = Get-AdoAuthHeader -PAT $PAT

#endregion

#region Collect Metrics

Write-Host "Fetching agent pools..."
$allPools = Get-AgentPools -Organization $orgName -Headers $headers

if (-not $allPools -or $allPools.Count -eq 0) {
    Write-Warning "No agent pools found for organization '$orgName'. Nothing to report."
    exit 0
}

Write-Host "Found $($allPools.Count) agent pool(s). Collecting health metrics..."
Write-Host ""

$poolMetrics = @()

foreach ($pool in $allPools) {
    try {
        $metrics = Get-AgentPoolHealthMetrics -Organization $orgName -Pool $pool -Headers $headers
        $poolMetrics += $metrics

        # Console output with color coding
        $statusEmoji = switch ($metrics.HealthState) {
            'Critical' { '🔴 [CRIT]' }
            'Warning'  { '🟡 [WARN]' }
            default    { '🟢 [OK]  ' }
        }

        $color = switch ($metrics.HealthState) {
            'Critical' { 'Red' }
            'Warning'  { 'Yellow' }
            default    { 'Green' }
        }

        $line = "$statusEmoji $($metrics.PoolName.PadRight(40)) " +
                "Queued: $($metrics.QueuedJobs.ToString().PadLeft(3))  " +
                "Running: $($metrics.RunningJobs.ToString().PadLeft(3))  " +
                "Oldest: $($metrics.OldestQueuedMinutes.ToString('F1').PadLeft(6)) min"

        Write-Host $line -ForegroundColor $color

        # Push individual metrics to Azure Monitor if enabled
        if ($enableMetricsPush) {
            $dimensions = @{
                PoolId   = $metrics.PoolId.ToString()
                PoolName = $metrics.PoolName
                PoolType = $metrics.PoolType
                IsHosted = $metrics.IsHosted.ToString()
            }

            Send-OperationalMetric -MetricName 'AgentPoolQueuedJobs' `
                -Value $metrics.QueuedJobs `
                -Dimensions $dimensions `
                -Organization $orgName | Out-Null

            Send-OperationalMetric -MetricName 'AgentPoolRunningJobs' `
                -Value $metrics.RunningJobs `
                -Dimensions $dimensions `
                -Organization $orgName | Out-Null

            Send-OperationalMetric -MetricName 'AgentPoolOldestQueued' `
                -Value $metrics.OldestQueuedMinutes `
                -Dimensions $dimensions `
                -Organization $orgName | Out-Null
        }
    }
    catch {
        Write-Warning "Error collecting metrics for pool '$($pool.name)': $($_.Exception.Message)"
        # Continue processing remaining pools even if one fails
    }
}

#endregion

#region Summary Calculation

$criticalCount = ($poolMetrics | Where-Object { $_.HealthState -eq 'Critical' }).Count
$warningCount  = ($poolMetrics | Where-Object { $_.HealthState -eq 'Warning'  }).Count
$healthyCount  = ($poolMetrics | Where-Object { $_.HealthState -eq 'Healthy'  }).Count
$totalCount    = $poolMetrics.Count

$summary = [ordered]@{
    Critical = $criticalCount
    Warning  = $warningCount
    Healthy  = $healthyCount
    Total    = $totalCount
}

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host " Summary: $healthyCount Healthy  |  $warningCount Warning  |  $criticalCount Critical  (Total: $totalCount)"
Write-Host "------------------------------------------------------------"

#endregion

#region Generate JSON Report

$generatedUtc   = [DateTime]::UtcNow
$generatedLocal = [DateTime]::Now

$jsonReport = [ordered]@{
    Organization    = $orgName
    GeneratedUtc    = $generatedUtc.ToString('o')
    GeneratedLocal  = $generatedLocal.ToString('o')
    Summary         = $summary
    HealthCriteria  = [ordered]@{
        Critical = "OldestQueuedMinutes >= 15 OR QueuedJobs >= 10"
        Warning  = "OldestQueuedMinutes >= 5  OR QueuedJobs >= 5"
        Healthy  = "All metrics below Warning thresholds"
    }
    Pools = @($poolMetrics | ForEach-Object {
        [ordered]@{
            PoolId              = $_.PoolId
            PoolName            = $_.PoolName
            PoolType            = $_.PoolType
            IsHosted            = $_.IsHosted
            QueuedJobs          = $_.QueuedJobs
            RunningJobs         = $_.RunningJobs
            OldestQueuedMinutes = $_.OldestQueuedMinutes
            HealthState         = $_.HealthState
            Timestamp           = $_.Timestamp
        }
    })
}

$jsonOutputPath = Join-Path $OutputPath 'agent-pool-health.json'
$jsonReport | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonOutputPath -Encoding UTF8

Write-Host ""
Write-Host "JSON report saved: $jsonOutputPath"

#endregion

#region Generate Markdown Report

$mdTimestampUtc   = $generatedUtc.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
$mdTimestampLocal = $generatedLocal.ToString('yyyy-MM-dd HH:mm:ss zzz')

$markdownLines = @()

$markdownLines += "# Azure DevOps Agent Pool Health Report"
$markdownLines += ""
$markdownLines += "**Organization:** ``$orgName``"
$markdownLines += ""
$markdownLines += "**Generated:** $mdTimestampUtc ($mdTimestampLocal local)"
$markdownLines += ""
$markdownLines += "---"
$markdownLines += ""
$markdownLines += "## Health Criteria"
$markdownLines += ""
$markdownLines += "| State | Condition |"
$markdownLines += "|-------|-----------|"
$markdownLines += "| 🔴 Critical | Oldest queued job >= **15 min** OR >= **10 jobs** in queue |"
$markdownLines += "| 🟡 Warning  | Oldest queued job >= **5 min**  OR >= **5 jobs** in queue |"
$markdownLines += "| 🟢 Healthy  | All metrics below Warning thresholds |"
$markdownLines += ""
$markdownLines += "---"
$markdownLines += ""
$markdownLines += "## Summary"
$markdownLines += ""
$markdownLines += "| 🟢 Healthy | 🟡 Warning | 🔴 Critical | Total |"
$markdownLines += "|-----------|-----------|------------|-------|"
$markdownLines += "| $healthyCount | $warningCount | $criticalCount | $totalCount |"
$markdownLines += ""
$markdownLines += "---"
$markdownLines += ""
$markdownLines += "## Pool Status"
$markdownLines += ""
$markdownLines += "| Pool | Type | Hosted | Queued | Running | Oldest Queued (min) | Health State |"
$markdownLines += "|------|------|--------|--------|---------|---------------------|--------------|"

foreach ($m in ($poolMetrics | Sort-Object HealthState, PoolName)) {
    $stateCell = switch ($m.HealthState) {
        'Critical' { '🔴 **Critical**' }
        'Warning'  { '🟡 Warning'      }
        default    { '🟢 Healthy'      }
    }

    $hostedCell = if ($m.IsHosted) { 'Yes' } else { 'No' }

    $markdownLines += "| $($m.PoolName) | $($m.PoolType) | $hostedCell | $($m.QueuedJobs) | $($m.RunningJobs) | $($m.OldestQueuedMinutes.ToString('F1')) | $stateCell |"
}

$markdownLines += ""
$markdownLines += "---"
$markdownLines += ""
$markdownLines += "*Report generated by ADO Metrics Monitoring. " +
    "See [README](../../README.md) for setup instructions.*"
$markdownLines += ""

$mdOutputPath = Join-Path $OutputPath 'agent-pool-health.md'
$markdownLines -join "`n" | Set-Content -Path $mdOutputPath -Encoding UTF8

Write-Host "Markdown report saved: $mdOutputPath"

#endregion

#region Exit Code

Write-Host ""

if ($criticalCount -gt 0) {
    Write-Host "⚠️  ATTENTION: $criticalCount pool(s) are in CRITICAL state!" -ForegroundColor Red
    Write-Host "Exiting with code 1 to signal pipeline failure." -ForegroundColor Red
    exit 1
}
elseif ($warningCount -gt 0) {
    Write-Host "⚠️  NOTICE: $warningCount pool(s) are in WARNING state." -ForegroundColor Yellow
    Write-Host "Exiting with code 0 (warnings do not fail the pipeline)." -ForegroundColor Yellow
    exit 0
}
else {
    Write-Host "✅ All $healthyCount pool(s) are HEALTHY." -ForegroundColor Green
    exit 0
}

#endregion
