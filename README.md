# Jira Project Issue Exporter (PowerShell)

Exports all issues from a Jira project (on-prem/server/data center) using Jira REST API with pagination.

Script: `Export-JiraProjectIssues.ps1`

## Features

- Exports every issue for a project via JQL
- Handles pagination automatically
- Auto-detects Jira API base path (including `/jira` context path)
- Supports auth with:
  - Personal access token (Bearer)
  - `JIRA_TOKEN` environment variable fallback
  - Basic auth credential prompt fallback
- Outputs:
  - Full JSON export
  - Flattened CSV export

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- Network access to Jira
- Jira API permissions to search/view issues in the target project

## Authentication Priority

1. `-PersonalAccessToken` parameter
2. `JIRA_TOKEN` environment variable (Process/User/Machine)
3. `-Credential` parameter or interactive credential prompt

## Usage

### 1) Use environment variable token (recommended)

```powershell
$env:JIRA_TOKEN = "your-token-here"
.\Export-JiraProjectIssues.ps1 -JiraBaseUrl "https://jira.example.com" -ProjectKey "ABC"
```

### 2) Pass token directly

```powershell
.\Export-JiraProjectIssues.ps1 -JiraBaseUrl "https://jira.example.com" -ProjectKey "ABC" -PersonalAccessToken "your-token-here"
```

### 3) Use credential prompt (basic auth)

```powershell
.\Export-JiraProjectIssues.ps1 -JiraBaseUrl "https://jira.example.com" -ProjectKey "ABC"
```

### 4) Custom output folder and page size

```powershell
.\Export-JiraProjectIssues.ps1 -JiraBaseUrl "https://jira.example.com" -ProjectKey "ABC" -OutputDirectory ".\out" -PageSize 200
```

### 5) JSON only (skip CSV)

```powershell
.\Export-JiraProjectIssues.ps1 -JiraBaseUrl "https://jira.example.com" -ProjectKey "ABC" -SkipCsv
```

## Parameters

- `-JiraBaseUrl` (required): Jira base URL, for example `https://jira.example.com`
- `-ProjectKey` (required): Jira project key, for example `ABC`
- `-OutputDirectory` (optional): Default `./exports`
- `-Jql` (optional): Overrides default JQL (`project = "<ProjectKey>" ORDER BY key ASC`)
- `-PageSize` (optional): Default `100`, allowed `1..1000`
- `-PersonalAccessToken` (optional): Bearer token
- `-Credential` (optional): PSCredential for basic auth
- `-SkipCsv` (optional): Do not generate CSV

## Output

Generated files (timestamped):

- `exports/jira-<PROJECT>-<yyyyMMdd-HHmmss>.json`
- `exports/jira-<PROJECT>-<yyyyMMdd-HHmmss>.csv` (unless `-SkipCsv`)

## Troubleshooting

### Received HTML login/SSO content instead of JSON

This usually means Jira redirected to your SSO login flow. Ensure:

- Token/credentials are valid
- Token has Jira API access
- You are using the correct Jira host/context path

### 400/401/403 errors during probe/search

- Verify project key is correct
- Verify token scopes/permissions
- Try explicitly setting `-JiraBaseUrl` to include context path if needed (for example `https://jira.example.com/jira`)

### Exports folder tracked by git

The repo includes `.gitignore` with `exports/` so generated files are ignored.
