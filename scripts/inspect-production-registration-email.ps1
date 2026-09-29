[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
if (-not (Test-Path -LiteralPath $docker)) {
  throw 'Docker CLI was not found.'
}

$authId = (& $docker ps --filter 'name=auth' --format '{{.ID}} {{.Names}} {{.Status}}' |
  Where-Object { $_ -match 'family|passport|supabase' } |
  Select-Object -First 1)
if (-not $authId) {
  throw 'No FamilyDocuments Auth container was found.'
}
$parts = $authId -split ' ', 3
$id = $parts[0]
$environment = & $docker inspect $id --format '{{range .Config.Env}}{{println .}}{{end}}'
$keys = @(
  'GOTRUE_SMTP_HOST',
  'GOTRUE_SMTP_PORT',
  'GOTRUE_SMTP_USER',
  'GOTRUE_SMTP_PASS',
  'GOTRUE_SMTP_ADMIN_EMAIL',
  'GOTRUE_MAILER_AUTOCONFIRM',
  'GOTRUE_MAILER_URLPATHS_CONFIRMATION'
)
$report = [ordered]@{
  checked_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  container = $parts[1]
  status = $parts[2]
  mail_settings_present = [ordered]@{}
  sanitized_recent_mailer_lines = @()
}
foreach ($key in $keys) {
  $report.mail_settings_present[$key] = [bool]($environment | Where-Object { $_ -match "^$key=" })
}
$report.sanitized_recent_mailer_lines = @(
  (& $docker logs --since 24h $id 2>&1 |
    Select-String -Pattern 'smtp|mailer|confirm|email|error|fail' |
    ForEach-Object {
      $_.Line `
        -replace '(?i)(password|token|secret|pass)=\S+', '$1=[redacted]' `
        -replace '(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', '[email]'
    } |
    Select-Object -Last 80)
)
$directory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
