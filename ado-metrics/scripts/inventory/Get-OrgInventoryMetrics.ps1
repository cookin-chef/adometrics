<#
.SYNOPSIS
    Azure DevOps organization inventory metrics collection functions.
.DESCRIPTION
    Provides functions to collect a comprehensive inventory of an ADO organization:
    projects, repositories, users, pipelines (with hosting breakdown), and
    SonarQube integration counts. Uses REST API v7.1.
    Import this module from Run-OrgInventory.ps1.
#>

function Get-AllProjects {
    <#
    .SYNOPSIS
        Retrieve all projects in the Azure DevOps organization.
    .DESCRIPTION
        Uses pagination to retrieve all projects regardless of organization size.
    .PARAMETER Organization
        Azure DevOps organization name.
    .PARAMETER Headers
        Authentication headers hashtable.
    .OUTPUTS
        Array of project objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $uri = "https://dev.azure.com/$Organization/_apis/projects?api-version=7.1&`$top=200"
    Write-Verbose "Fetching all projects from: $uri"

    try {
        $projects = Get-AdoApiPaginated -Uri $uri -Headers $Headers
        Write-Verbose "Total projects retrieved: $($projects.Count)"
        return $projects
    }
    catch {
        Write-Error "Failed to retrieve projects for organization '$Organization': $($_.Exception.Message)"
        throw
    }
}


function Get-TotalRepositoryCount {
    <#
    .SYNOPSIS
        Count the total number of Git repositories across all projects.
    .PARAMETER Organization
        Azure DevOps organization name.
    .PARAMETER Projects
        Array of project objects (from Get-AllProjects).
    .PARAMETER Headers
        Authentication headers hashtable.
    .OUTPUTS
        Integer total repository count.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $totalRepos = 0

    foreach ($project in $Projects) {
        $projectName = [Uri]::EscapeDataString($project.name)
        $uri = "https://dev.azure.com/$Organization/$projectName/_apis/git/repositories?api-version=7.1"

        try {
            $response   = Invoke-AdoApiRequest -Uri $uri -Headers $Headers -Method GET
            $repoCount  = if ($response.count) { $response.count } else { $response.value.Count }
            $totalRepos += $repoCount
            Write-Verbose "Project '$($project.name)': $repoCount repositories"
        }
        catch {
            Write-Warning "Could not retrieve repositories for project '$($project.name)': $($_.Exception.Message)"
        }
    }

    Write-Verbose "Total repositories across all projects: $totalRepos"
    return $totalRepos
}


function Get-TotalUserCount {
    <#
    .SYNOPSIS
        Get the total number of users in the organization.
    .DESCRIPTION
        First tries the Graph API (requires more permissions), falls back to
        the User Entitlements API which only requires basic access.
        Returns 0 on all errors.
    .PARAMETER Organization
        Azure DevOps organization name.
    .PARAMETER Headers
        Authentication headers hashtable.
    .OUTPUTS
        Integer user count.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    # Attempt 1: Graph API (requires Graph (read) scope on PAT)
    try {
        Write-Verbose "Attempting Graph API for user count..."
        $graphUri = "https://vssps.dev.azure.com/$Organization/_apis/graph/users?api-version=7.1-preview.1"
        $users    = Get-AdoApiPaginated -Uri $graphUri -Headers $Headers

        if ($users -and $users.Count -gt 0) {
            Write-Verbose "Graph API returned $($users.Count) users"
            return $users.Count
        }
    }
    catch {
        Write-Verbose "Graph API user count failed (may require additional PAT scopes): $($_.Exception.Message)"
    }

    # Attempt 2: User Entitlements API fallback
    try {
        Write-Verbose "Falling back to User Entitlements API for user count..."
        $entitlementsUri = "https://dev.azure.com/$Organization/_apis/userentitlements?api-version=7.1-preview.3&`$top=1"
        $response        = Invoke-AdoApiRequest -Uri $entitlementsUri -Headers $Headers -Method GET

        $count = if ($response.totalCount) {
            [int]$response.totalCount
        }
        elseif ($response.members) {
            $response.members.Count
        }
        else {
            0
        }

        Write-Verbose "User Entitlements API returned count: $count"
        return $count
    }
    catch {
        Write-Warning "Could not retrieve user count via any available API: $($_.Exception.Message)"
        return 0
    }
}


function Get-PipelineHostingBreakdown {
    <#
    .SYNOPSIS
        Count pipelines by hosting type across all projects.
    .DESCRIPTION
        Iterates all pipelines in all projects and classifies each as
        MicrosoftHosted, SelfHosted, or Unknown based on queue/pool name heuristics.

        Heuristics:
          MicrosoftHosted : queue name contains "azure pipelines", "hosted", or "microsoft"
          SelfHosted      : queue name contains "self", "default", or "private"
          Unknown         : none of the above match
    .PARAMETER Organization
        Azure DevOps organization name.
    .PARAMETER Projects
        Array of project objects (from Get-AllProjects).
    .PARAMETER Headers
        Authentication headers hashtable.
    .OUTPUTS
        Hashtable: {Total, MicrosoftHosted, SelfHosted, Unknown}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $breakdown = @{
        Total           = 0
        MicrosoftHosted = 0
        SelfHosted      = 0
        Unknown         = 0
    }

    foreach ($project in $Projects) {
        $projectName        = [Uri]::EscapeDataString($project.name)
        $pipelinesUri       = "https://dev.azure.com/$Organization/$projectName/_apis/pipelines?api-version=7.1"

        try {
            $response  = Invoke-AdoApiRequest -Uri $pipelinesUri -Headers $Headers -Method GET
            $pipelines = $response.value

            if (-not $pipelines -or $pipelines.Count -eq 0) {
                Write-Verbose "Project '$($project.name)': no pipelines found"
                continue
            }

            Write-Verbose "Project '$($project.name)': $($pipelines.Count) pipelines found"

            foreach ($pipeline in $pipelines) {
                $breakdown.Total++

                # Get pipeline details to determine agent queue
                try {
                    $detailUri    = "https://dev.azure.com/$Organization/$projectName/_apis/pipelines/$($pipeline.id)?api-version=7.1"
                    $detail       = Invoke-AdoApiRequest -Uri $detailUri -Headers $Headers -Method GET

                    # Extract pool/queue name from the pipeline configuration
                    $queueName = $null

                    # Check YAML pipeline pool property
                    if ($detail.configuration -and $detail.configuration.repository) {
                        # YAML-based pipeline - pool is defined in YAML, try to infer from folder name
                        $queueName = $detail.configuration.repository.defaultBranch
                    }

                    # Try the queue property directly
                    if (-not $queueName -and $detail.queue) {
                        $queueName = $detail.queue.name
                    }

                    if (-not $queueName -and $detail.configuration -and $detail.configuration.designerJson) {
                        $designerJson = $detail.configuration.designerJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($designerJson -and $designerJson.queue) {
                            $queueName = $designerJson.queue.name
                        }
                    }

                    $hostingType = Resolve-PipelineHostingType -QueueName $queueName
                    $breakdown[$hostingType]++
                }
                catch {
                    Write-Verbose "Could not get details for pipeline $($pipeline.id) in '$($project.name)': $($_.Exception.Message)"
                    $breakdown.Unknown++
                }
            }
        }
        catch {
            Write-Warning "Could not retrieve pipelines for project '$($project.name)': $($_.Exception.Message)"
        }
    }

    Write-Verbose "Pipeline hosting breakdown: Total=$($breakdown.Total), MS-Hosted=$($breakdown.MicrosoftHosted), Self-Hosted=$($breakdown.SelfHosted), Unknown=$($breakdown.Unknown)"
    return $breakdown
}


function Resolve-PipelineHostingType {
    <#
    .SYNOPSIS
        Classify a pipeline's hosting type based on the queue/pool name.
    .PARAMETER QueueName
        The queue or pool name string to classify.
    .OUTPUTS
        String: "MicrosoftHosted", "SelfHosted", or "Unknown"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$QueueName
    )

    if ([string]::IsNullOrWhiteSpace($QueueName)) {
        return 'Unknown'
    }

    $lower = $QueueName.ToLower()

    if ($lower -match 'azure pipelines|hosted|microsoft') {
        return 'MicrosoftHosted'
    }
    elseif ($lower -match '\bself\b|default|private') {
        return 'SelfHosted'
    }
    else {
        return 'Unknown'
    }
}


function Get-SonarQubeIntegrationCount {
    <#
    .SYNOPSIS
        Count build definitions that appear to integrate with SonarQube.
    .DESCRIPTION
        Scans build definition names across all projects for "sonar" or "SonarQube"
        keywords. This is a heuristic and may not catch all integrations.
    .PARAMETER Organization
        Azure DevOps organization name.
    .PARAMETER Projects
        Array of project objects (from Get-AllProjects).
    .PARAMETER Headers
        Authentication headers hashtable.
    .OUTPUTS
        Integer count of build definitions with SonarQube in their name.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $sonarCount = 0

    foreach ($project in $Projects) {
        $projectName     = [Uri]::EscapeDataString($project.name)
        $definitionsUri  = "https://dev.azure.com/$Organization/$projectName/_apis/build/definitions?api-version=7.1"

        try {
            $response    = Invoke-AdoApiRequest -Uri $definitionsUri -Headers $Headers -Method GET
            $definitions = $response.value

            if (-not $definitions) { continue }

            $sonarDefs = @($definitions | Where-Object {
                $_.name -match 'sonar'
            })

            $sonarCount += $sonarDefs.Count
            Write-Verbose "Project '$($project.name)': $($sonarDefs.Count) SonarQube build definition(s)"
        }
        catch {
            Write-Warning "Could not retrieve build definitions for project '$($project.name)': $($_.Exception.Message)"
        }
    }

    Write-Verbose "Total SonarQube integrated build definitions: $sonarCount"
    return $sonarCount
}


function Get-OrganizationInventoryMetrics {
    <#
    .SYNOPSIS
        Collect a complete organizational inventory snapshot.
    .DESCRIPTION
        Calls all inventory sub-functions and assembles the results into a
        single metrics object.
    .PARAMETER Organization
        Azure DevOps organization name.
    .PARAMETER Headers
        Authentication headers hashtable.
    .OUTPUTS
        Ordered hashtable with all inventory metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    Write-Host "  [1/5] Fetching all projects..."
    $projects      = Get-AllProjects -Organization $Organization -Headers $Headers
    $totalProjects = $projects.Count
    Write-Host "        Found $totalProjects project(s)"

    Write-Host "  [2/5] Counting repositories..."
    $totalRepos    = Get-TotalRepositoryCount -Organization $Organization -Projects $projects -Headers $Headers
    Write-Host "        Found $totalRepos repository(ies)"

    Write-Host "  [3/5] Counting users..."
    $totalUsers    = Get-TotalUserCount -Organization $Organization -Headers $Headers
    Write-Host "        Found $totalUsers user(s)"

    Write-Host "  [4/5] Analyzing pipeline hosting breakdown..."
    $pipelineBreakdown = Get-PipelineHostingBreakdown -Organization $Organization -Projects $projects -Headers $Headers
    Write-Host "        Total: $($pipelineBreakdown.Total) pipelines " +
               "(MS-Hosted: $($pipelineBreakdown.MicrosoftHosted), " +
               "Self-Hosted: $($pipelineBreakdown.SelfHosted), " +
               "Unknown: $($pipelineBreakdown.Unknown))"

    Write-Host "  [5/5] Counting SonarQube integrations..."
    $sonarCount    = Get-SonarQubeIntegrationCount -Organization $Organization -Projects $projects -Headers $Headers
    Write-Host "        Found $sonarCount SonarQube-integrated pipeline(s)"

    return [ordered]@{
        TotalProjects                = $totalProjects
        TotalRepos                   = $totalRepos
        TotalUsers                   = $totalUsers
        TotalPipelines               = $pipelineBreakdown.Total
        MicrosoftHostedPipelines     = $pipelineBreakdown.MicrosoftHosted
        SelfHostedPipelines          = $pipelineBreakdown.SelfHosted
        UnknownPipelines             = $pipelineBreakdown.Unknown
        SonarQubeIntegratedPipelines = $sonarCount
        Timestamp                    = [DateTime]::UtcNow.ToString('o')
    }
}
