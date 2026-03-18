<#
.SYNOPSIS
    Azure Monitor Log Analytics HTTP Data Collector API helper functions.
.DESCRIPTION
    Provides functions to push ADO metrics to Azure Monitor Log Analytics
    using the HTTP Data Collector API (custom logs). Designed to degrade
    gracefully - pipeline never fails because of metrics push failures.

    Required environment variables:
      ENABLE_METRICS_PUSH          - set to "true" to enable pushing
      LOG_ANALYTICS_WORKSPACE_ID   - Log Analytics workspace GUID
      LOG_ANALYTICS_SHARED_KEY     - Primary or secondary shared key
#>

#region Private Helpers

function Build-Signature {
    <#
    .SYNOPSIS
        Build HMAC-SHA256 signature for Log Analytics Data Collector API.
    .PARAMETER WorkspaceId
        Log Analytics workspace ID (GUID).
    .PARAMETER SharedKey
        Log Analytics primary or secondary shared key (Base64 encoded).
    .PARAMETER Date
        RFC 1123 formatted date string (e.g. "Thu, 18 Mar 2026 12:00:00 GMT").
    .PARAMETER ContentLength
        Length in bytes of the JSON body being posted.
    .OUTPUTS
        Authorization header value string: "SharedKey {workspaceId}:{signature}"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceId,

        [Parameter(Mandatory = $true)]
        [string]$SharedKey,

        [Parameter(Mandatory = $true)]
        [string]$Date,

        [Parameter(Mandatory = $true)]
        [int]$ContentLength
    )

    # Build the string to sign per Log Analytics API documentation
    $stringToHash = "POST`n$ContentLength`napplication/json`nx-ms-date:$Date`n/api/logs"

    Write-Verbose "String to hash: $stringToHash"

    # Decode the shared key and compute HMAC-SHA256
    $keyBytes       = [Convert]::FromBase64String($SharedKey)
    $messageBytes   = [System.Text.Encoding]::UTF8.GetBytes($stringToHash)
    $hmacSha256     = New-Object System.Security.Cryptography.HMACSHA256
    $hmacSha256.Key = $keyBytes
    $hashBytes      = $hmacSha256.ComputeHash($messageBytes)
    $base64Hash     = [Convert]::ToBase64String($hashBytes)

    $signature = "SharedKey ${WorkspaceId}:${base64Hash}"
    Write-Verbose "Signature built successfully"
    return $signature
}

#endregion

#region Public Functions

function Post-LogAnalyticsData {
    <#
    .SYNOPSIS
        POST a JSON array of records to Azure Monitor Log Analytics.
    .DESCRIPTION
        Uses the HTTP Data Collector API. Gracefully handles errors without
        throwing - a metrics push failure never breaks the calling pipeline.
    .PARAMETER WorkspaceId
        Log Analytics workspace ID (GUID).
    .PARAMETER SharedKey
        Log Analytics primary or secondary shared key (Base64 encoded).
    .PARAMETER LogType
        Name of the custom log table (without the _CL suffix). E.g. "ADOOperationalMetrics".
    .PARAMETER Records
        Array of objects/hashtables to send as log records.
    .PARAMETER TimeGeneratedField
        Field name in records that contains the timestamp (default: "Timestamp").
    .OUTPUTS
        Boolean - $true if POST succeeded, $false on any error.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceId,

        [Parameter(Mandatory = $true)]
        [string]$SharedKey,

        [Parameter(Mandatory = $true)]
        [string]$LogType,

        [Parameter(Mandatory = $true)]
        [object[]]$Records,

        [Parameter(Mandatory = $false)]
        [string]$TimeGeneratedField = 'Timestamp'
    )

    try {
        $jsonBody      = $Records | ConvertTo-Json -Depth 10 -Compress
        $bodyBytes     = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        $contentLength = $bodyBytes.Length

        $rfc1123Date   = [DateTime]::UtcNow.ToString('r')   # RFC 1123 format

        $signature = Build-Signature `
            -WorkspaceId   $WorkspaceId `
            -SharedKey     $SharedKey `
            -Date          $rfc1123Date `
            -ContentLength $contentLength

        $uri = "https://$WorkspaceId.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"

        $headers = @{
            'Authorization'        = $signature
            'Log-Type'             = $LogType
            'x-ms-date'            = $rfc1123Date
            'time-generated-field' = $TimeGeneratedField
            'Content-Type'         = 'application/json'
        }

        Write-Verbose "Posting $($Records.Count) records to Log Analytics table: ${LogType}_CL"

        $response = Invoke-WebRequest `
            -Uri     $uri `
            -Method  POST `
            -Headers $headers `
            -Body    $bodyBytes `
            -ErrorAction Stop

        if ($response.StatusCode -eq 200) {
            Write-Verbose "Log Analytics POST succeeded (HTTP 200) for table: ${LogType}_CL"
            return $true
        }
        else {
            Write-Warning "Log Analytics POST returned unexpected status: $($response.StatusCode)"
            return $false
        }
    }
    catch {
        # Graceful degradation: warn but don't throw
        Write-Warning "Failed to post metrics to Log Analytics table '${LogType}_CL': $($_.Exception.Message)"
        Write-Verbose "Log Analytics error details: $_"
        return $false
    }
}


function Send-OperationalMetric {
    <#
    .SYNOPSIS
        Send a single operational metric to ADOOperationalMetrics_CL table.
    .PARAMETER MetricName
        Name of the metric (e.g. "AgentPoolQueuedJobs").
    .PARAMETER Value
        Numeric value of the metric.
    .PARAMETER Dimensions
        Optional hashtable of additional dimension fields.
    .PARAMETER Organization
        Azure DevOps organization name.
    .OUTPUTS
        Boolean - $true if metric was sent (or metrics push is disabled).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MetricName,

        [Parameter(Mandatory = $true)]
        [double]$Value,

        [Parameter(Mandatory = $false)]
        [hashtable]$Dimensions = @{},

        [Parameter(Mandatory = $true)]
        [string]$Organization
    )

    $workspaceId = $env:LOG_ANALYTICS_WORKSPACE_ID
    $sharedKey   = $env:LOG_ANALYTICS_SHARED_KEY

    if ([string]::IsNullOrWhiteSpace($workspaceId) -or [string]::IsNullOrWhiteSpace($sharedKey)) {
        Write-Verbose "Log Analytics credentials not configured - skipping operational metric: $MetricName"
        return $true
    }

    $record = [ordered]@{
        Timestamp    = [DateTime]::UtcNow.ToString('o')   # ISO 8601
        MetricName   = $MetricName
        Value        = $Value
        Organization = $Organization
        Namespace    = 'ADO/Operations'
    }

    # Merge dimensions into the record
    foreach ($key in $Dimensions.Keys) {
        $record[$key] = $Dimensions[$key]
    }

    return Post-LogAnalyticsData `
        -WorkspaceId $workspaceId `
        -SharedKey   $sharedKey `
        -LogType     'ADOOperationalMetrics' `
        -Records     @($record)
}


function Send-InventoryMetric {
    <#
    .SYNOPSIS
        Send a single inventory metric to ADOInventoryMetrics_CL table.
    .PARAMETER MetricName
        Name of the metric (e.g. "TotalProjects").
    .PARAMETER Value
        Numeric value of the metric.
    .PARAMETER Dimensions
        Optional hashtable of additional dimension fields.
    .PARAMETER Organization
        Azure DevOps organization name.
    .OUTPUTS
        Boolean - $true if metric was sent (or metrics push is disabled).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MetricName,

        [Parameter(Mandatory = $true)]
        [double]$Value,

        [Parameter(Mandatory = $false)]
        [hashtable]$Dimensions = @{},

        [Parameter(Mandatory = $true)]
        [string]$Organization
    )

    $workspaceId = $env:LOG_ANALYTICS_WORKSPACE_ID
    $sharedKey   = $env:LOG_ANALYTICS_SHARED_KEY

    if ([string]::IsNullOrWhiteSpace($workspaceId) -or [string]::IsNullOrWhiteSpace($sharedKey)) {
        Write-Verbose "Log Analytics credentials not configured - skipping inventory metric: $MetricName"
        return $true
    }

    $record = [ordered]@{
        Timestamp    = [DateTime]::UtcNow.ToString('o')
        Date         = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
        MetricName   = $MetricName
        Value        = $Value
        Organization = $Organization
        Namespace    = 'ADO/Inventory'
    }

    foreach ($key in $Dimensions.Keys) {
        $record[$key] = $Dimensions[$key]
    }

    return Post-LogAnalyticsData `
        -WorkspaceId $workspaceId `
        -SharedKey   $sharedKey `
        -LogType     'ADOInventoryMetrics' `
        -Records     @($record)
}


function Send-MetricBatch {
    <#
    .SYNOPSIS
        Send multiple metrics of mixed types in a single batch operation.
    .DESCRIPTION
        Groups metrics by type (Operational|Inventory) and sends each group
        to the appropriate Log Analytics table.
    .PARAMETER Metrics
        Array of metric objects. Each must have:
          MetricName  (string)
          Value       (double)
          Type        (string: "Operational" or "Inventory")
          Organization (string)
          Dimensions  (hashtable, optional)
    .OUTPUTS
        Boolean - $true if all batches succeeded.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Metrics
    )

    $workspaceId = $env:LOG_ANALYTICS_WORKSPACE_ID
    $sharedKey   = $env:LOG_ANALYTICS_SHARED_KEY

    if ([string]::IsNullOrWhiteSpace($workspaceId) -or [string]::IsNullOrWhiteSpace($sharedKey)) {
        Write-Verbose "Log Analytics credentials not configured - skipping metric batch of $($Metrics.Count) items"
        return $true
    }

    $now         = [DateTime]::UtcNow
    $allSucceeded = $true

    # Group metrics by type
    $operationalMetrics = $Metrics | Where-Object { $_.Type -eq 'Operational' }
    $inventoryMetrics   = $Metrics | Where-Object { $_.Type -eq 'Inventory' }

    # Build and send operational records
    if ($operationalMetrics) {
        $opRecords = foreach ($m in $operationalMetrics) {
            $record = [ordered]@{
                Timestamp    = $now.ToString('o')
                MetricName   = $m.MetricName
                Value        = [double]$m.Value
                Organization = $m.Organization
                Namespace    = 'ADO/Operations'
            }
            if ($m.Dimensions) {
                foreach ($key in $m.Dimensions.Keys) { $record[$key] = $m.Dimensions[$key] }
            }
            $record
        }

        Write-Verbose "Sending batch of $($opRecords.Count) operational metrics"
        $result = Post-LogAnalyticsData `
            -WorkspaceId $workspaceId `
            -SharedKey   $sharedKey `
            -LogType     'ADOOperationalMetrics' `
            -Records     $opRecords

        if (-not $result) { $allSucceeded = $false }
    }

    # Build and send inventory records
    if ($inventoryMetrics) {
        $invRecords = foreach ($m in $inventoryMetrics) {
            $record = [ordered]@{
                Timestamp    = $now.ToString('o')
                Date         = $now.ToString('yyyy-MM-dd')
                MetricName   = $m.MetricName
                Value        = [double]$m.Value
                Organization = $m.Organization
                Namespace    = 'ADO/Inventory'
            }
            if ($m.Dimensions) {
                foreach ($key in $m.Dimensions.Keys) { $record[$key] = $m.Dimensions[$key] }
            }
            $record
        }

        Write-Verbose "Sending batch of $($invRecords.Count) inventory metrics"
        $result = Post-LogAnalyticsData `
            -WorkspaceId $workspaceId `
            -SharedKey   $sharedKey `
            -LogType     'ADOInventoryMetrics' `
            -Records     $invRecords

        if (-not $result) { $allSucceeded = $false }
    }

    return $allSucceeded
}


function Test-MetricsConnection {
    <#
    .SYNOPSIS
        Send a test metric to verify Log Analytics workspace credentials are valid.
    .DESCRIPTION
        Reads workspace ID and key from environment variables and sends a
        connectivity test record. Useful for validating configuration before
        running full metrics collection.
    .OUTPUTS
        Boolean - $true if the test metric was accepted by Log Analytics.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $enablePush  = $env:ENABLE_METRICS_PUSH
    $workspaceId = $env:LOG_ANALYTICS_WORKSPACE_ID
    $sharedKey   = $env:LOG_ANALYTICS_SHARED_KEY

    Write-Host "Checking metrics push configuration..."
    Write-Host "  ENABLE_METRICS_PUSH: $enablePush"
    Write-Host "  LOG_ANALYTICS_WORKSPACE_ID: $(if ($workspaceId) { $workspaceId.Substring(0, [Math]::Min(8, $workspaceId.Length)) + '...' } else { '(not set)' })"
    Write-Host "  LOG_ANALYTICS_SHARED_KEY: $(if ($sharedKey) { '(set, length ' + $sharedKey.Length + ')' } else { '(not set)' })"

    if ($enablePush -ne 'true') {
        Write-Warning "ENABLE_METRICS_PUSH is not set to 'true'. Metrics push is disabled."
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($workspaceId)) {
        Write-Error "LOG_ANALYTICS_WORKSPACE_ID environment variable is not set."
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($sharedKey)) {
        Write-Error "LOG_ANALYTICS_SHARED_KEY environment variable is not set."
        return $false
    }

    Write-Host "Sending test metric to Log Analytics..."

    $testRecord = @{
        Timestamp    = [DateTime]::UtcNow.ToString('o')
        MetricName   = 'ConnectivityTest'
        Value        = 1
        Organization = 'test'
        Namespace    = 'ADO/Test'
        TestRun      = $true
    }

    $result = Post-LogAnalyticsData `
        -WorkspaceId $workspaceId `
        -SharedKey   $sharedKey `
        -LogType     'ADOOperationalMetrics' `
        -Records     @($testRecord)

    if ($result) {
        Write-Host "SUCCESS: Test metric posted to Log Analytics successfully." -ForegroundColor Green
        Write-Host "  Note: Data ingestion may take 5-15 minutes before appearing in queries."
    }
    else {
        Write-Warning "FAILED: Could not post test metric. Check workspace ID and shared key."
    }

    return $result
}

#endregion
