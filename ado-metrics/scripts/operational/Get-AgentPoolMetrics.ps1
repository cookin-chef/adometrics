<#
.SYNOPSIS
    Azure DevOps agent pool metrics collection functions.
.DESCRIPTION
    Provides functions to collect health and utilization metrics from
    Azure DevOps agent pools using REST API v7.1.
    Import this module from Run-AgentPoolHealth.ps1.
#>

function Get-AgentPools {
    <#
    .SYNOPSIS
        Retrieve all agent pools from the Azure DevOps organization.
    .PARAMETER Organization
        Azure DevOps organization name (clean, no URL prefix).
    .PARAMETER Headers
        Authentication headers hashtable.
    .OUTPUTS
        Array of agent pool objects.
    .EXAMPLE
        $pools = Get-AgentPools -Organization "myorg" -Headers $headers
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $uri = "https://dev.azure.com/$Organization/_apis/distributedtask/pools?api-version=7.1-preview.1"
    Write-Verbose "Fetching agent pools from: $uri"

    try {
        $pools = Get-AdoApiPaginated -Uri $uri -Headers $Headers

        Write-Verbose "Retrieved $($pools.Count) agent pools"
        return $pools
    }
    catch {
        Write-Error "Failed to retrieve agent pools for organization '$Organization': $($_.Exception.Message)"
        throw
    }
}


function Get-PoolJobRequests {
    <#
    .SYNOPSIS
        Get all job requests for a specific agent pool.
    .PARAMETER Organization
        Azure DevOps organization name.
    .PARAMETER PoolId
        Numeric ID of the agent pool.
    .PARAMETER Headers
        Authentication headers hashtable.
    .OUTPUTS
        Array of job request objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [int]$PoolId,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $uri = "https://dev.azure.com/$Organization/_apis/distributedtask/pools/$PoolId/jobrequests?api-version=7.1"
    Write-Verbose "Fetching job requests for pool ID $PoolId from: $uri"

    try {
        $response = Invoke-AdoApiRequest -Uri $uri -Headers $Headers -Method GET
        $requests = $response.value

        Write-Verbose "Pool $PoolId : retrieved $($requests.Count) job requests"
        return $requests
    }
    catch {
        Write-Warning "Failed to retrieve job requests for pool $PoolId : $($_.Exception.Message)"
        return @()
    }
}


function Get-QueuedJobsCount {
    <#
    .SYNOPSIS
        Count jobs that are queued but not yet assigned to an agent.
    .DESCRIPTION
        A job is considered "queued" when it has a requestId but no assignTime,
        meaning it is waiting for an available agent.
    .PARAMETER JobRequests
        Array of job request objects from Get-PoolJobRequests.
    .OUTPUTS
        Integer count of queued jobs.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$JobRequests
    )

    if (-not $JobRequests -or $JobRequests.Count -eq 0) {
        return 0
    }

    $queued = @($JobRequests | Where-Object {
        $_.requestId -and
        -not $_.assignTime
    })

    Write-Verbose "Queued jobs (requestId present, assignTime null): $($queued.Count)"
    return $queued.Count
}


function Get-RunningJobsCount {
    <#
    .SYNOPSIS
        Count jobs that are actively running on an agent.
    .DESCRIPTION
        A job is "running" when it has an assignTime (picked up by agent)
        but no finishTime yet.
    .PARAMETER JobRequests
        Array of job request objects from Get-PoolJobRequests.
    .OUTPUTS
        Integer count of running jobs.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$JobRequests
    )

    if (-not $JobRequests -or $JobRequests.Count -eq 0) {
        return 0
    }

    $running = @($JobRequests | Where-Object {
        $_.assignTime -and
        -not $_.finishTime
    })

    Write-Verbose "Running jobs (assignTime present, finishTime null): $($running.Count)"
    return $running.Count
}


function Get-OldestQueuedMinutes {
    <#
    .SYNOPSIS
        Calculate how long the oldest queued job has been waiting.
    .DESCRIPTION
        Finds jobs that are queued (requestId present, assignTime null),
        sorts by queueTime ascending, and returns the wait time in minutes
        for the oldest one. Returns 0 if there are no queued jobs.
    .PARAMETER JobRequests
        Array of job request objects from Get-PoolJobRequests.
    .OUTPUTS
        Double - minutes the oldest queued job has been waiting (1 decimal place).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$JobRequests
    )

    if (-not $JobRequests -or $JobRequests.Count -eq 0) {
        return 0.0
    }

    # Get only queued jobs (waiting for agent)
    $queuedJobs = @($JobRequests | Where-Object {
        $_.requestId -and
        -not $_.assignTime -and
        $_.queueTime
    })

    if ($queuedJobs.Count -eq 0) {
        Write-Verbose "No queued jobs with valid queueTime found"
        return 0.0
    }

    # Sort ascending to find the oldest job
    $sortedByQueueTime = $queuedJobs | Sort-Object {
        [DateTime]::Parse($_.queueTime)
    }

    $oldestJob      = $sortedByQueueTime[0]
    $queuedAt       = [DateTime]::Parse($oldestJob.queueTime).ToUniversalTime()
    $now            = [DateTime]::UtcNow
    $waitMinutes    = ($now - $queuedAt).TotalMinutes

    $rounded = [Math]::Round($waitMinutes, 1)
    Write-Verbose "Oldest queued job has been waiting $rounded minutes (queued at: $queuedAt UTC)"
    return $rounded
}


function Get-AgentPoolHealthMetrics {
    <#
    .SYNOPSIS
        Collect all health metrics for a single agent pool.
    .DESCRIPTION
        Combines queue depth, running job count, and oldest queue wait time
        into a single health record with a calculated HealthState.

        Health State Criteria:
          Critical : OldestQueuedMinutes >= 15  OR  QueuedJobs >= 10
          Warning  : OldestQueuedMinutes >= 5   OR  QueuedJobs >= 5
          Healthy  : all metrics below Warning thresholds
    .PARAMETER Organization
        Azure DevOps organization name.
    .PARAMETER Pool
        Agent pool object (from Get-AgentPools).
    .PARAMETER Headers
        Authentication headers hashtable.
    .OUTPUTS
        Ordered hashtable with pool health metrics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,

        [Parameter(Mandatory = $true)]
        [object]$Pool,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $poolId   = $Pool.id
    $poolName = $Pool.name
    $poolType = $Pool.poolType
    $isHosted = $Pool.isHosted

    Write-Verbose "Collecting metrics for pool: $poolName (ID: $poolId, Type: $poolType, Hosted: $isHosted)"

    # Retrieve current job requests
    $jobRequests = Get-PoolJobRequests -Organization $Organization -PoolId $poolId -Headers $Headers

    # Compute individual metrics
    $queuedJobs          = Get-QueuedJobsCount    -JobRequests $jobRequests
    $runningJobs         = Get-RunningJobsCount   -JobRequests $jobRequests
    $oldestQueuedMinutes = Get-OldestQueuedMinutes -JobRequests $jobRequests

    # Determine health state
    $healthState = if ($oldestQueuedMinutes -ge 15 -or $queuedJobs -ge 10) {
        'Critical'
    }
    elseif ($oldestQueuedMinutes -ge 5 -or $queuedJobs -ge 5) {
        'Warning'
    }
    else {
        'Healthy'
    }

    Write-Verbose "Pool '$poolName' health: $healthState (Queued: $queuedJobs, Running: $runningJobs, OldestQueued: ${oldestQueuedMinutes}min)"

    return [ordered]@{
        PoolId               = $poolId
        PoolName             = $poolName
        PoolType             = $poolType
        IsHosted             = [bool]$isHosted
        QueuedJobs           = $queuedJobs
        RunningJobs          = $runningJobs
        OldestQueuedMinutes  = $oldestQueuedMinutes
        HealthState          = $healthState
        Timestamp            = [DateTime]::UtcNow.ToString('o')
    }
}
