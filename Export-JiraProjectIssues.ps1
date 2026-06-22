[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JiraBaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$ProjectKey,

    [string]$OutputDirectory = ".\exports",

    [string]$Jql,

    [ValidateRange(1, 1000)]
    [int]$PageSize = 100,

    [string]$PersonalAccessToken,

    [PSCredential]$Credential,

    [switch]$SkipCsv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-HttpErrorDetails {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $statusCode = $null
    $statusDescription = $null
    $responseText = $null

    if ($Exception.PSObject.Properties.Name -contains "Response" -and $null -ne $Exception.Response) {
        try {
            $statusCode = [int]$Exception.Response.StatusCode
        }
        catch {
            $statusCode = $null
        }

        try {
            $statusDescription = [string]$Exception.Response.StatusDescription
        }
        catch {
            $statusDescription = $null
        }

        try {
            $stream = $Exception.Response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $responseText = $reader.ReadToEnd()
                $reader.Dispose()
                $stream.Dispose()
            }
        }
        catch {
            $responseText = $null
        }
    }

    [PSCustomObject]@{
        StatusCode        = $statusCode
        StatusDescription = $statusDescription
        ResponseBody      = $responseText
        ExceptionMessage  = $Exception.Message
    }
}

function Invoke-JiraRestMethod {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [string]$Body
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Body)) {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
        }

        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $Body
    }
    catch {
        $details = Get-HttpErrorDetails -Exception $_.Exception
        $message = "Jira API call failed: {0} {1}" -f $Method, $Uri

        if ($null -ne $details.StatusCode) {
            $message += " | HTTP $($details.StatusCode)"
        }

        if (-not [string]::IsNullOrWhiteSpace($details.StatusDescription)) {
            $message += " $($details.StatusDescription)"
        }

        if ($null -eq $details.StatusCode -and -not [string]::IsNullOrWhiteSpace($details.ExceptionMessage)) {
            $message += " | Exception: $($details.ExceptionMessage)"
        }

        if (-not [string]::IsNullOrWhiteSpace($details.ResponseBody)) {
            $message += "`nResponse body: $($details.ResponseBody)"
        }

        throw $message
    }
}

function Get-JiraBaseUrlCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawBaseUrl
    )

    $trimmed = $RawBaseUrl.Trim().TrimEnd("/")
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        $candidates.Add($trimmed)
    }

    if ($trimmed -notmatch "/jira$" -and $trimmed -notmatch "/jira/.*$") {
        $candidates.Add("$trimmed/jira")
    }

    return $candidates | Select-Object -Unique
}

function Resolve-JiraSearchUri {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$BaseUrls,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [int]$PageSize
    )

    $candidateUris = New-Object System.Collections.Generic.List[string]
    foreach ($base in $BaseUrls) {
        $candidateUris.Add("$base/rest/api/2/search")
        $candidateUris.Add("$base/rest/api/latest/search")
        $candidateUris.Add("$base/rest/api/3/search")
    }

    $candidateUris = $candidateUris | Select-Object -Unique

    # Neutral probe query so endpoint detection does not depend on project key validity.
    $probeJql = "ORDER BY created DESC"
    $encodedProbeJql = [System.Uri]::EscapeDataString($probeJql)

    $probeFailures = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in $candidateUris) {
        $probeUri = "{0}?jql={1}&startAt=0&maxResults={2}&fields=key" -f $candidate, $encodedProbeJql, [Math]::Min($PageSize, 1)

        try {
            $probeResponse = Invoke-RestMethod -Method Get -Uri $probeUri -Headers $Headers
            $probeProps = @($probeResponse.PSObject.Properties.Name)

            if ($probeResponse -is [string]) {
                if ($probeResponse -match "<html" -or $probeResponse -match "openid-connect/auth" -or $probeResponse -match "window.location.assign") {
                    $probeFailures.Add("$candidate => received HTML login/SSO redirect instead of Jira JSON")
                    continue
                }
            }

            if (($probeProps -contains "issues") -and ($probeProps -contains "total")) {
                Write-Host "Using Jira search endpoint: $candidate"
                return $candidate
            }

            $probeFailures.Add(("$candidate => non-search payload fields: [{0}]" -f ($probeProps -join ", ")))
        }
        catch {
            $details = Get-HttpErrorDetails -Exception $_.Exception

            if ($details.StatusCode -eq 400 -and -not [string]::IsNullOrWhiteSpace($details.ResponseBody)) {
                if ($details.ResponseBody -match '"errorMessages"' -or $details.ResponseBody -match '"errors"') {
                    Write-Host "Using Jira search endpoint (probe returned API validation error, endpoint is reachable): $candidate"
                    return $candidate
                }
            }

            if ($details.StatusCode -in @(404, 405)) {
                Write-Host "Search endpoint not available: $candidate"
                continue
            }

            if ($details.StatusCode -in @(401, 403)) {
                $probeFailures.Add(("$candidate => HTTP {0} (auth/permission)" -f $details.StatusCode))
                continue
            }

            if ($null -ne $details.StatusCode) {
                $probeFailures.Add(("$candidate => HTTP {0}" -f $details.StatusCode))
            }
            else {
                $probeFailures.Add(("$candidate => request failed without HTTP status: {0}" -f $details.ExceptionMessage))
            }
        }
    }

    $failureSummary = ""
    if ($probeFailures.Count -gt 0) {
        $failureSummary = " Probe failures: " + ($probeFailures -join "; ")
    }

    throw "Could not find a valid Jira search endpoint. Tried: $($candidateUris -join ', '). Try using a Jira URL that includes the context path, for example https://host/jira.$failureSummary"
}

function Get-AuthHeaders {
    param(
        [string]$Pat,
        [PSCredential]$Cred
    )

    $normalizedPat = $null
    if ($null -ne $Pat) {
        $normalizedPat = $Pat.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($normalizedPat)) {
        return @{ Authorization = "Bearer $normalizedPat" }
    }

    if ($null -eq $Cred) {
        $Cred = Get-Credential -Message "Enter Jira username and password/API token"
    }

    $plainPassword = $Cred.GetNetworkCredential().Password
    $pair = "{0}:{1}" -f $Cred.UserName, $plainPassword
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    $base64 = [Convert]::ToBase64String($bytes)

    return @{ Authorization = "Basic $base64" }
}

function New-IssueCsvRow {
    param(
        [Parameter(Mandatory = $true)]
        $Issue
    )

    $fields = $Issue.fields

    $labels = @()
    if ($fields.PSObject.Properties.Name -contains "labels" -and $null -ne $fields.labels) {
        $labels = @($fields.labels)
    }

    $components = @()
    if ($fields.PSObject.Properties.Name -contains "components" -and $null -ne $fields.components) {
        $components = @($fields.components | ForEach-Object { $_.name })
    }

    $fixVersions = @()
    if ($fields.PSObject.Properties.Name -contains "fixVersions" -and $null -ne $fields.fixVersions) {
        $fixVersions = @($fields.fixVersions | ForEach-Object { $_.name })
    }

    $assignee = $null
    if ($fields.PSObject.Properties.Name -contains "assignee" -and $null -ne $fields.assignee) {
        if ($fields.assignee.PSObject.Properties.Name -contains "displayName") {
            $assignee = $fields.assignee.displayName
        }
        elseif ($fields.assignee.PSObject.Properties.Name -contains "name") {
            $assignee = $fields.assignee.name
        }
    }

    $reporter = $null
    if ($fields.PSObject.Properties.Name -contains "reporter" -and $null -ne $fields.reporter) {
        if ($fields.reporter.PSObject.Properties.Name -contains "displayName") {
            $reporter = $fields.reporter.displayName
        }
        elseif ($fields.reporter.PSObject.Properties.Name -contains "name") {
            $reporter = $fields.reporter.name
        }
    }

    $status = $null
    if ($fields.PSObject.Properties.Name -contains "status" -and $null -ne $fields.status) {
        $status = $fields.status.name
    }

    $issueType = $null
    if ($fields.PSObject.Properties.Name -contains "issuetype" -and $null -ne $fields.issuetype) {
        $issueType = $fields.issuetype.name
    }

    [PSCustomObject]@{
        key         = $Issue.key
        id          = $Issue.id
        summary     = $fields.summary
        issueType   = $issueType
        status      = $status
        priority    = if ($fields.priority) { $fields.priority.name } else { $null }
        assignee    = $assignee
        reporter    = $reporter
        created     = $fields.created
        updated     = $fields.updated
        resolution  = if ($fields.resolution) { $fields.resolution.name } else { $null }
        labels      = ($labels -join ";")
        components  = ($components -join ";")
        fixVersions = ($fixVersions -join ";")
    }
}

function Write-IssueChunk {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Issues,

        [Parameter(Mandatory = $true)]
        [string]$ProjectKey,

        [Parameter(Mandatory = $true)]
        [string]$Timestamp,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $true)]
        [int]$ChunkNumber,

        [switch]$SkipCsv
    )

    if ($Issues.Count -eq 0) {
        return
    }

    $partSuffix = "{0:D4}" -f $ChunkNumber
    $jsonPath = Join-Path $OutputDirectory ("jira-{0}-{1}-part{2}.json" -f $ProjectKey, $Timestamp, $partSuffix)
    $csvPath = Join-Path $OutputDirectory ("jira-{0}-{1}-part{2}.csv" -f $ProjectKey, $Timestamp, $partSuffix)

    $Issues | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    Write-Host "Wrote JSON export chunk: $jsonPath"

    if (-not $SkipCsv) {
        $csvRows = $Issues | ForEach-Object { New-IssueCsvRow -Issue $_ }
        $csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Wrote CSV export chunk: $csvPath"
    }
    else {
        Write-Host "Skipping CSV export for chunk $partSuffix due to -SkipCsv"
    }
}

$baseUrlCandidates = Get-JiraBaseUrlCandidates -RawBaseUrl $JiraBaseUrl

# Check for PAT token: parameter -> env var (Process/User/Machine) -> null (credential prompt)
if ([string]::IsNullOrWhiteSpace($PersonalAccessToken)) {
    $tokenFromEnv = [Environment]::GetEnvironmentVariable("JIRA_TOKEN", "Process")
    if ([string]::IsNullOrWhiteSpace($tokenFromEnv)) {
        $tokenFromEnv = [Environment]::GetEnvironmentVariable("JIRA_TOKEN", "User")
    }
    if ([string]::IsNullOrWhiteSpace($tokenFromEnv)) {
        $tokenFromEnv = [Environment]::GetEnvironmentVariable("JIRA_TOKEN", "Machine")
    }

    if ($null -ne $tokenFromEnv) {
        $tokenFromEnv = $tokenFromEnv.Trim()
    }

    $PersonalAccessToken = $tokenFromEnv
}

if ([string]::IsNullOrWhiteSpace($Jql)) {
    $Jql = "project = `"$ProjectKey`" ORDER BY key ASC"
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory | Out-Null
}

$headers = Get-AuthHeaders -Pat $PersonalAccessToken -Cred $Credential
$headers["Accept"] = "application/json"
$headers["Content-Type"] = "application/json"
$headers["X-Atlassian-Token"] = "no-check"

$searchUri = Resolve-JiraSearchUri -BaseUrls $baseUrlCandidates -Headers $headers -PageSize $PageSize

$chunkSize = 500
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$chunkIssues = New-Object System.Collections.Generic.List[object]
$chunkNumber = 1
$exportedCount = 0
$startAt = 0
$total = $null

Write-Host "Starting Jira export from project $ProjectKey"
Write-Host "JQL: $Jql"

while ($true) {
    $encodedJql = [System.Uri]::EscapeDataString($Jql)
    $requestUri = "{0}?jql={1}&startAt={2}&maxResults={3}&fields={4}" -f $searchUri, $encodedJql, $startAt, $PageSize, [System.Uri]::EscapeDataString("*all")

    $response = Invoke-JiraRestMethod -Method Get -Uri $requestUri -Headers $headers

    $responseProps = @($response.PSObject.Properties.Name)
    if (-not ($responseProps -contains "issues") -or -not ($responseProps -contains "total")) {
        $keys = $responseProps -join ", "
        $apiError = $null

        if ($responseProps -contains "errorMessages" -and $null -ne $response.errorMessages) {
            $apiError = (@($response.errorMessages) -join "; ")
        }
        elseif ($responseProps -contains "message" -and -not [string]::IsNullOrWhiteSpace([string]$response.message)) {
            $apiError = [string]$response.message
        }

        $preview = $null
        try {
            $preview = $response | ConvertTo-Json -Depth 6 -Compress
        }
        catch {
            $preview = [string]$response
        }

        $detail = "Unexpected Jira search response shape from $requestUri. Expected fields: issues,total. Received fields: [$keys]."
        if (-not [string]::IsNullOrWhiteSpace($apiError)) {
            $detail += " API error: $apiError"
        }
        if (-not [string]::IsNullOrWhiteSpace($preview)) {
            $detail += " Response preview: $preview"
        }

        throw $detail
    }

    if ($null -eq $total) {
        $total = [int]$response.total
        Write-Host "Total issues reported by Jira: $total"
    }

    $batch = @($response.issues)
    foreach ($issue in $batch) {
        $chunkIssues.Add($issue)
        $exportedCount += 1

        if ($chunkIssues.Count -ge $chunkSize) {
            Write-IssueChunk -Issues $chunkIssues -ProjectKey $ProjectKey -Timestamp $timestamp -OutputDirectory $OutputDirectory -ChunkNumber $chunkNumber -SkipCsv:$SkipCsv
            $chunkIssues.Clear()
            $chunkNumber += 1
        }
    }

    Write-Host ("Fetched {0} issues (running total: {1})" -f $batch.Count, $exportedCount)

    if ($batch.Count -eq 0) {
        break
    }

    $startAt += $batch.Count
    if ($startAt -ge $total) {
        break
    }
}

if ($chunkIssues.Count -gt 0) {
    Write-IssueChunk -Issues $chunkIssues -ProjectKey $ProjectKey -Timestamp $timestamp -OutputDirectory $OutputDirectory -ChunkNumber $chunkNumber -SkipCsv:$SkipCsv
    $chunkNumber += 1
}

if ($exportedCount -eq 0) {
    Write-Host "Done. No issues matched the query."
}
else {
    Write-Host ("Done. Exported {0} issues into {1} chunk(s) of up to {2} issues each." -f $exportedCount, ($chunkNumber - 1), $chunkSize)
}








