<#
.SYNOPSIS
    Azure DevOps HTTP helper functions with retry logic and pagination support.
.DESCRIPTION
    Provides robust HTTP request functions for Azure DevOps REST API v7.1,
    including exponential backoff retry, continuation token pagination,
    and organization name normalization.
#>

function Invoke-AdoApiRequest {
    <#
    .SYNOPSIS
        Make an HTTP request to the Azure DevOps REST API with retry logic.
    .DESCRIPTION
        Retries on transient errors (429, 500-504, timeouts, connection errors)
        with exponential backoff. Does NOT retry on 400-499 client errors (except 429).
    .PARAMETER Uri
        Full URL of the ADO REST API endpoint.
    .PARAMETER Headers
        Authentication and content-type headers hashtable.
    .PARAMETER Method
        HTTP method (default: GET).
    .PARAMETER Body
        Optional request body (for POST/PUT).
    .PARAMETER MaxRetries
        Maximum number of retry attempts (default: 3).
    .OUTPUTS
        Parsed response object from Invoke-RestMethod.
    .EXAMPLE
        $pools = Invoke-AdoApiRequest -Uri "https://dev.azure.com/myorg/_apis/distributedtask/pools?api-version=7.1" -Headers $headers
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [string]$Method = 'GET',

        [Parameter(Mandatory = $false)]
        [object]$Body = $null,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3
    )

    $attempt      = 0
    $lastError    = $null

    # Transient HTTP status codes that warrant a retry
    $retryStatusCodes = @(429, 500, 502, 503, 504)

    while ($attempt -le $MaxRetries) {
        try {
            Write-Verbose "[$Method] $Uri (attempt $($attempt + 1) of $($MaxRetries + 1))"

            $invokeParams = @{
                Uri         = $Uri
                Headers     = $Headers
                Method      = $Method
                ErrorAction = 'Stop'
            }

            if ($Body -ne $null) {
                $invokeParams['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress)
            }

            $response = Invoke-RestMethod @invokeParams
            Write-Verbose "Request succeeded on attempt $($attempt + 1)"
            return $response
        }
        catch [System.Net.WebException] {
            $webEx      = $_.Exception
            $statusCode = [int]$webEx.Response.StatusCode

            Write-Verbose "WebException caught. Status code: $statusCode. Message: $($webEx.Message)"

            # 4xx errors (except 429) are client errors - don't retry
            if ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429) {
                Write-Error "Client error $statusCode for URI: $Uri. Message: $($webEx.Message)"
                throw
            }

            $lastError = $_

            if ($attempt -lt $MaxRetries -and ($statusCode -in $retryStatusCodes -or $statusCode -eq 0)) {
                $backoffSeconds = [Math]::Pow(2, $attempt)
                Write-Warning "Request failed with status $statusCode. Retrying in $backoffSeconds seconds... (attempt $($attempt + 1)/$MaxRetries)"
                Start-Sleep -Seconds $backoffSeconds
            }
            else {
                Write-Error "Request failed after $($attempt + 1) attempts. Last error: $($webEx.Message)"
                throw
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
            Write-Verbose "General exception caught: $errorMessage"

            # Check for timeout or connection errors
            $isTransient = $errorMessage -match 'timeout|connection|network|reset|refused|unavailable' -or
                           $_.Exception -is [System.Net.WebException]

            $lastError = $_

            if ($attempt -lt $MaxRetries -and $isTransient) {
                $backoffSeconds = [Math]::Pow(2, $attempt)
                Write-Warning "Transient error: $errorMessage. Retrying in $backoffSeconds seconds... (attempt $($attempt + 1)/$MaxRetries)"
                Start-Sleep -Seconds $backoffSeconds
            }
            else {
                Write-Error "Request failed after $($attempt + 1) attempts. Last error: $errorMessage"
                throw
            }
        }

        $attempt++
    }

    # Should not reach here, but just in case
    throw $lastError
}


function Get-AdoApiPaginated {
    <#
    .SYNOPSIS
        Retrieve all pages of a paginated Azure DevOps REST API response.
    .DESCRIPTION
        Handles ADO continuation tokens, looping until all results are collected.
        Supports both query-parameter style and response-property style continuation tokens.
        Safety limit: 100 pages maximum.
    .PARAMETER Uri
        Base URL of the ADO REST API endpoint (without continuationToken parameter).
    .PARAMETER Headers
        Authentication and content-type headers hashtable.
    .PARAMETER MaxPages
        Maximum number of pages to retrieve (default: 100).
    .OUTPUTS
        Array containing all items from all pages.
    .EXAMPLE
        $projects = Get-AdoApiPaginated -Uri "https://dev.azure.com/myorg/_apis/projects?api-version=7.1" -Headers $headers
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [int]$MaxPages = 100
    )

    $allResults       = @()
    $continuationToken = $null
    $pageCount         = 0
    $currentUri        = $Uri

    do {
        $pageCount++

        if ($pageCount -gt $MaxPages) {
            Write-Warning "Reached maximum page limit ($MaxPages). Some results may be missing."
            break
        }

        # Append continuation token to URL if we have one
        if ($continuationToken) {
            $separator   = if ($currentUri -match '\?') { '&' } else { '?' }
            $currentUri  = "$Uri${separator}continuationToken=$([Uri]::EscapeDataString($continuationToken))"
        }

        Write-Verbose "Fetching page $pageCount from: $currentUri"

        # Use WebRequest to capture response headers for x-ms-continuationtoken
        try {
            $webResponse = Invoke-WebRequest -Uri $currentUri -Headers $Headers -Method GET -ErrorAction Stop
            $responseBody = $webResponse.Content | ConvertFrom-Json

            # Check for continuation token in response HEADERS (ADO standard)
            $headerToken = $webResponse.Headers['x-ms-continuationtoken']
            if ($headerToken) {
                $continuationToken = $headerToken
                Write-Verbose "Continuation token found in headers: $continuationToken"
            }
            # Check response BODY for continuation token
            elseif ($responseBody.continuationToken) {
                $continuationToken = $responseBody.continuationToken
                Write-Verbose "Continuation token found in body: $continuationToken"
            }
            else {
                $continuationToken = $null
                Write-Verbose "No continuation token found - this is the last page"
            }

            # Extract items from the value property or treat the whole response as the result
            if ($responseBody.PSObject.Properties.Name -contains 'value') {
                $pageItems = $responseBody.value
            }
            else {
                $pageItems = $responseBody
            }

            if ($pageItems) {
                $allResults += $pageItems
                Write-Verbose "Page $pageCount: retrieved $($pageItems.Count) items (total so far: $($allResults.Count))"
            }
            else {
                Write-Verbose "Page $pageCount: no items returned"
            }
        }
        catch {
            Write-Error "Failed to retrieve page $pageCount from $currentUri : $($_.Exception.Message)"
            throw
        }

    } while ($continuationToken)

    Write-Verbose "Pagination complete. Total pages: $pageCount, Total items: $($allResults.Count)"
    return $allResults
}


function Get-NormalizedOrgName {
    <#
    .SYNOPSIS
        Extract the clean organization name from an ADO URL or org name string.
    .DESCRIPTION
        Strips common ADO URL prefixes and trailing slashes to return just
        the organization name suitable for use in API calls.
    .PARAMETER OrgNameOrUrl
        Azure DevOps organization name or full URL.
    .OUTPUTS
        Clean organization name string.
    .EXAMPLE
        Get-NormalizedOrgName -OrgNameOrUrl "https://dev.azure.com/myorg/"  # returns "myorg"
        Get-NormalizedOrgName -OrgNameOrUrl "myorg.visualstudio.com"        # returns "myorg"
        Get-NormalizedOrgName -OrgNameOrUrl "myorg"                         # returns "myorg"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgNameOrUrl
    )

    $normalized = $OrgNameOrUrl.Trim()

    # Strip https://dev.azure.com/ prefix
    if ($normalized -match '^https?://dev\.azure\.com/([^/]+)') {
        $normalized = $Matches[1]
        Write-Verbose "Stripped dev.azure.com prefix, org name: $normalized"
        return $normalized.TrimEnd('/')
    }

    # Strip https://*.visualstudio.com/ prefix
    if ($normalized -match '^https?://([^.]+)\.visualstudio\.com') {
        $normalized = $Matches[1]
        Write-Verbose "Stripped visualstudio.com prefix, org name: $normalized"
        return $normalized.TrimEnd('/')
    }

    # Already a plain org name - just clean up
    $normalized = $normalized.TrimEnd('/')

    Write-Verbose "Org name normalized: $normalized"
    return $normalized
}
