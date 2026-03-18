<#
.SYNOPSIS
    Azure DevOps authentication helper functions.
.DESCRIPTION
    Provides PAT-based authentication header generation and validation
    for Azure DevOps REST API calls.
#>

function Get-AdoAuthHeader {
    <#
    .SYNOPSIS
        Generate Basic authentication headers for Azure DevOps REST API.
    .PARAMETER PAT
        Personal Access Token for Azure DevOps authentication.
    .OUTPUTS
        Hashtable with Authorization and Content-Type headers.
    .EXAMPLE
        $headers = Get-AdoAuthHeader -PAT $env:ADO_PAT
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PAT
    )

    Write-Verbose "Building ADO authentication headers"

    # Validate PAT before building header
    if (-not (Test-AdoPAT -PAT $PAT)) {
        throw "Invalid PAT token provided. Cannot build authentication headers."
    }

    # ADO expects ":PAT" (empty username) encoded as Base64
    $tokenBytes  = [System.Text.Encoding]::ASCII.GetBytes(":$PAT")
    $base64Token = [Convert]::ToBase64String($tokenBytes)

    $headers = @{
        'Authorization' = "Basic $base64Token"
        'Content-Type'  = 'application/json'
    }

    Write-Verbose "Authentication headers built successfully"
    return $headers
}


function Test-AdoPAT {
    <#
    .SYNOPSIS
        Validate that a PAT token looks structurally valid.
    .PARAMETER PAT
        Personal Access Token to validate.
    .OUTPUTS
        Boolean - $true if the PAT passes basic validation.
    .EXAMPLE
        if (-not (Test-AdoPAT -PAT $myPat)) { Write-Error "Bad PAT" }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$PAT
    )

    if ([string]::IsNullOrWhiteSpace($PAT)) {
        Write-Warning "PAT token is null or empty. Authentication will fail."
        return $false
    }

    if ($PAT.Length -lt 20) {
        Write-Warning "PAT token appears very short ($($PAT.Length) chars). " +
            "Valid PATs are typically 52+ characters. Proceeding, but authentication may fail."
    }

    Write-Verbose "PAT token passed basic validation (length: $($PAT.Length))"
    return $true
}
