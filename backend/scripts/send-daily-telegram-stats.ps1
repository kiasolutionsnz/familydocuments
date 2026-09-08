[CmdletBinding()]
param(
  [ValidatePattern('^\d{4}-\d{2}-\d{2}$')][string]$ReportDate,
  [switch]$DryRun,
  [switch]$Force
)
$ErrorActionPreference='Stop'
$docker='C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspace=Split-Path (Split-Path $root -Parent) -Parent
$monitoring=Join-Path $workspace 'platform\monitoring'
$tokenPath=Join-Path $monitoring 'secrets\telegram-bot-token'
$chatPath=Join-Path $monitoring 'secrets\telegram-chat-id'
$runtime=Join-Path $monitoring 'runtime'
$statePath=Join-Path $runtime 'familydocuments-daily-stats.json'

if(-not $ReportDate){
  $nz=[TimeZoneInfo]::FindSystemTimeZoneById('New Zealand Standard Time')
  $ReportDate=[TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow,$nz).Date.AddDays(-1).ToString('yyyy-MM-dd')
}

if(-not $Force -and (Test-Path -LiteralPath $statePath)){
  try{
    $state=Get-Content -Raw -LiteralPath $statePath|ConvertFrom-Json
    if($state.report_date -eq $ReportDate){Write-Output "already_sent=$ReportDate";exit 0}
  }catch{}
}

$sql=@"
with bounds as (
  select ('$ReportDate 00:00 Pacific/Auckland')::timestamptz as start_at,
         ('$ReportDate 00:00 Pacific/Auckland')::timestamptz + interval '1 day' as end_at
)
select concat_ws('|',
  (select count(*) from fp.app_usage_events,bounds where occurred_at>=start_at and occurred_at<end_at),
  (select count(distinct user_id) from fp.app_usage_events,bounds where occurred_at>=start_at and occurred_at<end_at),
  (select count(*) from auth.users,bounds where created_at>=start_at and created_at<end_at and deleted_at is null and not is_anonymous),
  (select count(*) from auth.users,bounds where email_confirmed_at>=start_at and email_confirmed_at<end_at and deleted_at is null and not is_anonymous),
  (select count(*) from auth.sessions,bounds where created_at>=start_at and created_at<end_at),
  (select count(*) from fp.documents,bounds where created_at>=start_at and created_at<end_at),
  (select count(*) from fp.reminders,bounds where created_at>=start_at and created_at<end_at),
  (select count(*) from fp.inbound_emails,bounds where ingested_at>=start_at and ingested_at<end_at)
);
"@

$row=& $docker exec family-passport-supabase-db-1 psql -U postgres -d postgres -tA -v ON_ERROR_STOP=1 -c $sql
if($LASTEXITCODE -ne 0){throw 'Family Documents statistics query failed.'}
$values=($row|Select-Object -Last 1).Trim().Split('|')
$invalidValues=@($values|Where-Object{$_ -notmatch '^\d+$'})
if($values.Count -ne 8 -or $invalidValues.Count -gt 0){throw 'Family Documents statistics returned an invalid aggregate result.'}
$message=@"
Family Documents — Daily summary
$ReportDate (Pacific/Auckland)

App opens: $($values[0])
Active users: $($values[1])
New registrations: $($values[2])
Accounts confirmed: $($values[3])
Sign-in sessions: $($values[4])
Documents added: $($values[5])
Reminders created: $($values[6])
Emails received: $($values[7])

Aggregate counts only — no personal or document content.
"@

if($DryRun){Write-Output $message;exit 0}
if(-not(Test-Path -LiteralPath $tokenPath)-or-not(Test-Path -LiteralPath $chatPath)){throw 'Telegram secret files are unavailable.'}
$token=(Get-Content -Raw -LiteralPath $tokenPath).Trim()
$chat=(Get-Content -Raw -LiteralPath $chatPath).Trim()
Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$token/sendMessage" -Body @{chat_id=$chat;text=$message;disable_web_page_preview='true'} -TimeoutSec 30|Out-Null
if(-not(Test-Path -LiteralPath $runtime)){New-Item -ItemType Directory -Path $runtime|Out-Null}
@{report_date=$ReportDate;sent_at=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress|Set-Content -LiteralPath $statePath -Encoding utf8
Write-Output "sent=$ReportDate"
