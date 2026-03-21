<#
.SYNOPSIS
    Run Azure DevOps organization inventory and generate reports.
.DESCRIPTION
    Collects organization-wide inventory metrics (projects, repos, users,
    pipelines, SonarQube integrations), generates JSON and Markdown reports,
    and optionally pushes metrics to Azure Monitor Log Analytics.
.PARAMETER Organization
    Azure DevOps organization name or URL.
.PARAMETER PAT
    Personal Access Token with appropriate read scopes.
.PARAMETER OutputPath
    Directory where report files will be written (default: ./output).
.EXAMPLE
    .\Run-OrgInventory.ps1 -Organization "myorg" -PAT $env:ADO_PAT
    .\Run-OrgInventory.ps1 -Organization "myorg" -PAT $env:ADO_PAT -OutputPath "C:\reports" -Verbose
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
. (Join-Path $PSScriptRoot 'Get-OrgInventoryMetrics.ps1')

# MetricsHelper is optional
$metricsHelperPath = Join-Path $libPath 'MetricsHelper.ps1'
$metricsAvailable  = Test-Path $metricsHelperPath
if ($metricsAvailable) {
    . $metricsHelperPath
    Write-Verbose "MetricsHelper loaded"
}
else {
    Write-Verbose "MetricsHelper not found - Azure Monitor push disabled"
}

#endregion

#region Initialization

$enableMetricsPush = ($env:ENABLE_METRICS_PUSH -eq 'true') -and $metricsAvailable

# Normalize organization name
$orgName = Get-NormalizedOrgName -OrgNameOrUrl $Organization

Write-Host ""
Write-Host "============================================================"
Write-Host " Azure DevOps Organization Inventory"
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

Write-Host "Collecting organization inventory metrics..."
Write-Host ""

$metrics = Get-OrganizationInventoryMetrics -Organization $orgName -Headers $headers

#endregion

#region Console Display

Write-Host ""
Write-Host "============================================================"
Write-Host " Organization Inventory Results"
Write-Host "============================================================"
Write-Host "  Projects                     : $($metrics.TotalProjects)"
Write-Host "  Repositories                 : $($metrics.TotalRepos)"
Write-Host "  Users                        : $($metrics.TotalUsers)"
Write-Host "  Total Pipelines              : $($metrics.TotalPipelines)"
Write-Host "  - Microsoft-Hosted           : $($metrics.MicrosoftHostedPipelines)"
Write-Host "  - Self-Hosted                : $($metrics.SelfHostedPipelines)"
Write-Host "  - Unknown                    : $($metrics.UnknownPipelines)"
Write-Host "  SonarQube Integrations       : $($metrics.SonarQubeIntegratedPipelines)"
Write-Host "============================================================"
Write-Host ""

#endregion

#region Push to Azure Monitor

if ($enableMetricsPush) {
    Write-Host "Pushing metrics to Azure Monitor Log Analytics..."

    $metricBatch = @(
        @{ MetricName = 'TotalProjects';                Value = $metrics.TotalProjects;                Type = 'Inventory'; Organization = $orgName; Dimensions = @{} }
        @{ MetricName = 'TotalRepos';                   Value = $metrics.TotalRepos;                   Type = 'Inventory'; Organization = $orgName; Dimensions = @{} }
        @{ MetricName = 'TotalUsers';                   Value = $metrics.TotalUsers;                   Type = 'Inventory'; Organization = $orgName; Dimensions = @{} }
        @{ MetricName = 'TotalPipelines';               Value = $metrics.TotalPipelines;               Type = 'Inventory'; Organization = $orgName; Dimensions = @{} }
        @{ MetricName = 'MicrosoftHostedPipelines';     Value = $metrics.MicrosoftHostedPipelines;     Type = 'Inventory'; Organization = $orgName; Dimensions = @{ HostingType = 'MicrosoftHosted' } }
        @{ MetricName = 'SelfHostedPipelines';          Value = $metrics.SelfHostedPipelines;          Type = 'Inventory'; Organization = $orgName; Dimensions = @{ HostingType = 'SelfHosted' } }
        @{ MetricName = 'UnknownPipelines';             Value = $metrics.UnknownPipelines;             Type = 'Inventory'; Organization = $orgName; Dimensions = @{ HostingType = 'Unknown' } }
        @{ MetricName = 'SonarQubeIntegratedPipelines'; Value = $metrics.SonarQubeIntegratedPipelines; Type = 'Inventory'; Organization = $orgName; Dimensions = @{} }
    )

    $pushResult = Send-MetricBatch -Metrics $metricBatch
    if ($pushResult) {
        Write-Host "Metrics pushed to Log Analytics successfully." -ForegroundColor Green
    }
    else {
        Write-Warning "One or more metric batches failed to push to Log Analytics (pipeline will continue)."
    }
}

#endregion

#region Generate JSON Report

$generatedUtc   = [DateTime]::UtcNow
$generatedLocal = [DateTime]::Now

$jsonReport = [ordered]@{
    Organization   = $orgName
    GeneratedUtc   = $generatedUtc.ToString('o')
    GeneratedLocal = $generatedLocal.ToString('o')
    Metrics        = [ordered]@{
        TotalProjects                = $metrics.TotalProjects
        TotalRepos                   = $metrics.TotalRepos
        TotalUsers                   = $metrics.TotalUsers
        TotalPipelines               = $metrics.TotalPipelines
        MicrosoftHostedPipelines     = $metrics.MicrosoftHostedPipelines
        SelfHostedPipelines          = $metrics.SelfHostedPipelines
        UnknownPipelines             = $metrics.UnknownPipelines
        SonarQubeIntegratedPipelines = $metrics.SonarQubeIntegratedPipelines
        Timestamp                    = $metrics.Timestamp
    }
}

$jsonOutputPath = Join-Path $OutputPath 'ado-org-metrics.json'
$jsonReport | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonOutputPath -Encoding UTF8
Write-Host "JSON report saved: $jsonOutputPath"

#endregion

#region Generate Markdown Report

$mdTimestampUtc = $generatedUtc.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
$mdDate         = $generatedUtc.ToString('yyyy-MM-dd')

# Calculate percentages for pipeline hosting
$pipelineTotal = $metrics.TotalPipelines
$msHostedPct   = if ($pipelineTotal -gt 0) { [Math]::Round(($metrics.MicrosoftHostedPipelines / $pipelineTotal) * 100, 1) } else { 0 }
$selfHostedPct = if ($pipelineTotal -gt 0) { [Math]::Round(($metrics.SelfHostedPipelines       / $pipelineTotal) * 100, 1) } else { 0 }
$unknownPct    = if ($pipelineTotal -gt 0) { [Math]::Round(($metrics.UnknownPipelines           / $pipelineTotal) * 100, 1) } else { 0 }

$markdownLines = @()

$markdownLines += "# Azure DevOps Organization Inventory"
$markdownLines += ""
$markdownLines += "**Organization:** ``$orgName``"
$markdownLines += ""
$markdownLines += "**Generated:** $mdTimestampUtc"
$markdownLines += ""
$markdownLines += "**Report Date:** $mdDate"
$markdownLines += ""
$markdownLines += "---"
$markdownLines += ""
$markdownLines += "## Overview"
$markdownLines += ""
$markdownLines += "| Metric | Value |"
$markdownLines += "|--------|-------|"
$markdownLines += "| Projects | $($metrics.TotalProjects) |"
$markdownLines += "| Repositories | $($metrics.TotalRepos) |"
$markdownLines += "| Users | $($metrics.TotalUsers) |"
$markdownLines += "| Total Pipelines | $($metrics.TotalPipelines) |"
$markdownLines += "| Microsoft-Hosted Pipelines | $($metrics.MicrosoftHostedPipelines) |"
$markdownLines += "| Self-Hosted Pipelines | $($metrics.SelfHostedPipelines) |"
$markdownLines += "| Unknown Pipelines | $($metrics.UnknownPipelines) |"
$markdownLines += "| SonarQube Integrations | $($metrics.SonarQubeIntegratedPipelines) |"
$markdownLines += ""
$markdownLines += "---"
$markdownLines += ""
$markdownLines += "## Pipeline Hosting Distribution"
$markdownLines += ""
$markdownLines += "| Hosting Type | Count | Percentage |"
$markdownLines += "|--------------|-------|------------|"
$markdownLines += "| Microsoft-Hosted | $($metrics.MicrosoftHostedPipelines) | ${msHostedPct}% |"
$markdownLines += "| Self-Hosted | $($metrics.SelfHostedPipelines) | ${selfHostedPct}% |"
$markdownLines += "| Unknown | $($metrics.UnknownPipelines) | ${unknownPct}% |"
$markdownLines += "| **Total** | **$($metrics.TotalPipelines)** | **100%** |"
$markdownLines += ""
$markdownLines += "---"
$markdownLines += ""
$markdownLines += "## Notes"
$markdownLines += ""
$markdownLines += "- **User count** is retrieved via the Graph API (preferred) or User Entitlements API (fallback)."
$markdownLines += "  A value of 0 may indicate insufficient PAT scopes."
$markdownLines += "- **Pipeline hosting classification** uses queue/pool name heuristics and may not be 100% accurate."
$markdownLines += "  Pipelines with custom pool names may appear as 'Unknown'."
$markdownLines += "- **SonarQube count** reflects build definition names containing 'sonar'. Pipeline steps are not analyzed."
$markdownLines += "- This report is generated daily at 10:00 UTC. For real-time data, query Azure Monitor Log Analytics."
$markdownLines += ""
$markdownLines += "---"
$markdownLines += ""
$markdownLines += "*Report generated by ADO Metrics Monitoring. " +
    "See [README](../../README.md) for setup instructions.*"
$markdownLines += ""

$mdOutputPath = Join-Path $OutputPath 'ado-org-metrics.md'
$markdownLines -join "`n" | Set-Content -Path $mdOutputPath -Encoding UTF8
Write-Host "Markdown report saved: $mdOutputPath"

#endregion

Write-Host ""
Write-Host "Organization inventory complete." -ForegroundColor Green
exit 0
