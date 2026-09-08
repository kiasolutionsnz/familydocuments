[CmdletBinding()]
param([switch]$DryRun,[switch]$Force)
$ErrorActionPreference='Stop'
$docker='C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspace=Split-Path (Split-Path $root -Parent) -Parent
$monitoring=Join-Path $workspace 'platform\monitoring'
$tokenPath=Join-Path $monitoring 'secrets\telegram-bot-token'
$chatPath=Join-Path $monitoring 'secrets\telegram-chat-id'
$runtime=Join-Path $monitoring 'runtime'
$statePath=Join-Path $runtime 'familydocuments-inbound-email-alert.json'
$recoveryStatePath=Join-Path $runtime 'familydocuments-inbound-email-recovery.json'
$recoveryWindow=[TimeSpan]::FromHours(1)
$recoveryLimit=3

function Read-RecoveryState{
  if(Test-Path -LiteralPath $recoveryStatePath){
    try{return Get-Content -Raw -LiteralPath $recoveryStatePath|ConvertFrom-Json}
    catch{}
  }
  return [pscustomobject]@{classifier=@();scanner=@();notifications=@()}
}

function Test-RecoveryAllowed([ValidateSet('classifier','scanner','notifications')][string]$Worker){
  $state=Read-RecoveryState
  $cutoff=[datetime]::UtcNow.Subtract($recoveryWindow)
  $recent=@($state.$Worker|Where-Object{
    try{([datetime]$_).ToUniversalTime()-gt$cutoff}catch{$false}
  })
  return $recent.Count-lt$recoveryLimit
}

function Record-RecoveryAttempt([ValidateSet('classifier','scanner','notifications')][string]$Worker){
  if($DryRun){return}
  $state=Read-RecoveryState
  $cutoff=[datetime]::UtcNow.Subtract($recoveryWindow)
  $classifier=@($state.classifier|Where-Object{try{([datetime]$_).ToUniversalTime()-gt$cutoff}catch{$false}})
  $scanner=@($state.scanner|Where-Object{try{([datetime]$_).ToUniversalTime()-gt$cutoff}catch{$false}})
  $notifications=@($state.notifications|Where-Object{try{([datetime]$_).ToUniversalTime()-gt$cutoff}catch{$false}})
  if($Worker-eq'classifier'){$classifier+=[datetime]::UtcNow.ToString('o')}
  elseif($Worker-eq'scanner'){$scanner+=[datetime]::UtcNow.ToString('o')}
  else{$notifications+=[datetime]::UtcNow.ToString('o')}
  if(-not(Test-Path -LiteralPath $runtime)){New-Item -ItemType Directory -Path $runtime|Out-Null}
  @{classifier=$classifier;scanner=$scanner;notifications=$notifications;updated_at=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress|Set-Content -LiteralPath $recoveryStatePath -Encoding utf8
}

function Get-ExactWorkerProcessCount([string]$Pattern){
  return @(Get-CimInstance Win32_Process -Filter "Name='node.exe'"|Where-Object{$_.CommandLine-match$Pattern}).Count
}

function Stop-ExactWorkerProcesses([string]$Pattern){
  Get-CimInstance Win32_Process -Filter "Name='node.exe'"|Where-Object{$_.CommandLine-match$Pattern}|ForEach-Object{
    Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
  }
}

function Send-PrivateAlert([string]$Message,[string]$Signature){
  if($DryRun){Write-Output $Message;return}
  if(-not(Test-Path -LiteralPath $tokenPath)-or-not(Test-Path -LiteralPath $chatPath)){throw 'Telegram secret files are unavailable.'}
  if(-not $Force -and (Test-Path -LiteralPath $statePath)){
    try{
      $state=Get-Content -Raw -LiteralPath $statePath|ConvertFrom-Json
      if($state.signature-eq$Signature-and([datetime]$state.sent_at).ToUniversalTime()-gt[datetime]::UtcNow.AddHours(-4)){
        Write-Output 'alert_suppressed=cooldown';return
      }
    }catch{}
  }
  $token=(Get-Content -Raw -LiteralPath $tokenPath).Trim()
  $chat=(Get-Content -Raw -LiteralPath $chatPath).Trim()
  Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$token/sendMessage" -Body @{chat_id=$chat;text=$Message;disable_web_page_preview='true'} -TimeoutSec 30|Out-Null
  if(-not(Test-Path -LiteralPath $runtime)){New-Item -ItemType Directory -Path $runtime|Out-Null}
  @{signature=$Signature;sent_at=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress|Set-Content -LiteralPath $statePath -Encoding utf8
  Write-Output 'alert_sent=true'
}

$sql=@"
select concat_ws('|',
  count(*) filter(where status='retry_wait' and attempts>=2),
  count(*) filter(where status='dead_letter'),
  count(*) filter(where status='processing' and locked_at<now()-interval '10 minutes'),
  count(*) filter(where status in ('pending','retry_wait') and next_attempt_at<now()-interval '10 minutes'),
  coalesce(floor(extract(epoch from now()-min(created_at)) / 60)::bigint,0),
  (select count(*) from fp.inbound_attachments where scan_status='pending' and created_at<now()-interval '2 minutes'),
  (select coalesce(floor(extract(epoch from now()-min(created_at)) / 60)::bigint,0) from fp.inbound_attachments where scan_status='pending'),
  (select count(*) from fp.inbound_emails e where e.sender_disposition='allowed' and e.deleted_at is null and e.processing_status='awaiting_classification' and e.attachment_count=0 and e.ingested_at<now()-interval '2 minutes' and not exists(select 1 from fp.email_classification_jobs j where j.inbound_email_id=e.id)),
  (select count(*) from fp.reminders r join fp.documents d on d.id=r.document_id and d.lifecycle_status='active' where r.status='upcoming' and r.due_at=(now() at time zone 'Pacific/Auckland')::date and (now() at time zone 'Pacific/Auckland')::time>=time '08:10' and not exists(select 1 from fp.notification_outbox o where o.kind='reminder' and o.dedupe_key like 'reminder_due_day:'||r.id::text||':%')),
  (select count(*) from fp.notification_outbox where kind='reminder' and dedupe_key like 'reminder_due_day:%' and status in ('pending','failed','sending') and available_at<now()-interval '10 minutes')
)
from fp.email_classification_jobs
where status in ('pending','processing','retry_wait','dead_letter');
"@

try{
  $row=& $docker exec family-passport-supabase-db-1 psql -U postgres -d postgres -tA -v ON_ERROR_STOP=1 -c $sql
  if($LASTEXITCODE-ne 0){throw 'database query failed'}
  $values=($row|Select-Object -Last 1).Trim().Split('|')
  if($values.Count-ne 10-or@($values|Where-Object{$_-notmatch'^\d+$'}).Count-gt 0){throw 'invalid aggregate result'}
}catch{
  Send-PrivateAlert 'Family Documents alert: inbound email processing health could not be checked. The home-server worker or database may be unavailable. No email content is included.' 'health_check_failed'
  exit 1
}

$retrying=[int]$values[0];$dead=[int]$values[1];$locked=[int]$values[2];$overdue=[int]$values[3];$oldest=[int]$values[4];$staleScans=[int]$values[5];$oldestScan=[int]$values[6];$orphanedBody=[int]$values[7];$dueDayMissing=[int]$values[8];$overdueNotifications=[int]$values[9]
$classifierTask='Kia Family Documents Classifier'
$scannerTask='Kia Family Documents Attachment Scanner'
$notificationTask='Kia Family Documents Notifications'
$classifierPattern='email-ingestion[\\/]classifier\.mjs'
$scannerPattern='email-ingestion[\\/]attachment-scanner\.mjs'
$notificationPattern='notifications[\\/]worker\.mjs'
$classifierRecoveryLimited=0;$scannerRecoveryLimited=0;$notificationRecoveryLimited=0
try{$classifierProcessCount=Get-ExactWorkerProcessCount $classifierPattern;$classifierDown=[int](((Get-ScheduledTask -TaskName $classifierTask -ErrorAction Stop).State-ne'Running')-or$classifierProcessCount-ne 1)}catch{$classifierProcessCount=0;$classifierDown=1}
try{$scannerProcessCount=Get-ExactWorkerProcessCount $scannerPattern;$scannerDown=[int](((Get-ScheduledTask -TaskName $scannerTask -ErrorAction Stop).State-ne'Running')-or$scannerProcessCount-ne 1)}catch{$scannerProcessCount=0;$scannerDown=1}
try{$notificationProcessCount=Get-ExactWorkerProcessCount $notificationPattern;$notificationDown=[int](((Get-ScheduledTask -TaskName $notificationTask -ErrorAction Stop).State-ne'Running')-or$notificationProcessCount-ne 1)}catch{$notificationProcessCount=0;$notificationDown=1}
if(($scannerDown+$staleScans)-gt 0-and-not $DryRun){
  if(-not(Test-RecoveryAllowed 'scanner')){
    $scannerRecoveryLimited=1
    Write-Output 'scanner_automatic_recovery=suppressed_by_hourly_limit'
  }else{
  try{
    Record-RecoveryAttempt 'scanner'
    $task=Get-ScheduledTask -TaskName $scannerTask -ErrorAction Stop
    if($task.State-eq'Running'){Stop-ScheduledTask -TaskName $scannerTask}
    Start-Sleep -Seconds 1
    Stop-ExactWorkerProcesses $scannerPattern
    Start-ScheduledTask -TaskName $scannerTask
    Start-Sleep -Seconds 20
    $task=Get-ScheduledTask -TaskName $scannerTask -ErrorAction Stop
    $remaining=(& $docker exec family-passport-supabase-db-1 psql -U postgres -d postgres -tA -v ON_ERROR_STOP=1 -c "select count(*) from fp.inbound_attachments where scan_status='pending' and created_at<now()-interval '2 minutes';"|Select-Object -Last 1).Trim()
    if($LASTEXITCODE-ne 0-or$remaining-notmatch'^\d+$'-or$task.State-ne'Running'-or(Get-ExactWorkerProcessCount $scannerPattern)-ne 1){throw 'scanner recovery verification failed'}
    if([int]$remaining-eq 0){
      Send-PrivateAlert 'Family Documents — automatic recovery succeeded. The attachment scanner was restarted and the pre-classification queue is moving again. No email content is included.' 'attachment_scanner_recovered'
      $scannerDown=0;$staleScans=0
    }
  }catch{Write-Output 'automatic_recovery=failed'}
  }
}
if(($classifierDown+$orphanedBody)-gt 0-and-not $DryRun){
  if(-not(Test-RecoveryAllowed 'classifier')){
    $classifierRecoveryLimited=1
    Write-Output 'classifier_automatic_recovery=suppressed_by_hourly_limit'
  }else{
  try{
    Record-RecoveryAttempt 'classifier'
    $task=Get-ScheduledTask -TaskName $classifierTask -ErrorAction Stop
    if($task.State-eq'Running'){Stop-ScheduledTask -TaskName $classifierTask}
    Start-Sleep -Seconds 1
    Stop-ExactWorkerProcesses $classifierPattern
    Start-ScheduledTask -TaskName $classifierTask
    Start-Sleep -Seconds 20
    $task=Get-ScheduledTask -TaskName $classifierTask -ErrorAction Stop
    $remaining=(& $docker exec family-passport-supabase-db-1 psql -U postgres -d postgres -tA -v ON_ERROR_STOP=1 -c "select count(*) from fp.inbound_emails e where e.sender_disposition='allowed' and e.deleted_at is null and e.processing_status='awaiting_classification' and e.attachment_count=0 and e.ingested_at<now()-interval '2 minutes' and not exists(select 1 from fp.email_classification_jobs j where j.inbound_email_id=e.id);"|Select-Object -Last 1).Trim()
    if($LASTEXITCODE-ne 0-or$remaining-notmatch'^\d+$'-or$task.State-ne'Running'-or(Get-ExactWorkerProcessCount $classifierPattern)-ne 1){throw 'classifier recovery verification failed'}
    if([int]$remaining-eq 0){
      Send-PrivateAlert 'Family Documents — automatic recovery succeeded. The classifier was restarted and the inbound email queue is moving again. No email content is included.' 'classifier_recovered'
      $classifierDown=0;$orphanedBody=0
    }
  }catch{Write-Output 'classifier_automatic_recovery=failed'}
  }
}
if(($notificationDown+$dueDayMissing+$overdueNotifications)-gt 0-and-not $DryRun){
  if(-not(Test-RecoveryAllowed 'notifications')){
    $notificationRecoveryLimited=1
    Write-Output 'notification_automatic_recovery=suppressed_by_hourly_limit'
  }else{
    try{
      Record-RecoveryAttempt 'notifications'
      $task=Get-ScheduledTask -TaskName $notificationTask -ErrorAction Stop
      if($task.State-eq'Running'){Stop-ScheduledTask -TaskName $notificationTask}
      Start-Sleep -Seconds 1
      Stop-ExactWorkerProcesses $notificationPattern
      Start-ScheduledTask -TaskName $notificationTask
      Start-Sleep -Seconds 20
      $task=Get-ScheduledTask -TaskName $notificationTask -ErrorAction Stop
      $remaining=(& $docker exec family-passport-supabase-db-1 psql -U postgres -d postgres -tA -v ON_ERROR_STOP=1 -c "select concat_ws('|',(select count(*) from fp.reminders r join fp.documents d on d.id=r.document_id and d.lifecycle_status='active' where r.status='upcoming' and r.due_at=(now() at time zone 'Pacific/Auckland')::date and (now() at time zone 'Pacific/Auckland')::time>=time '08:10' and not exists(select 1 from fp.notification_outbox o where o.kind='reminder' and o.dedupe_key like 'reminder_due_day:'||r.id::text||':%')),(select count(*) from fp.notification_outbox where kind='reminder' and dedupe_key like 'reminder_due_day:%' and status in ('pending','failed','sending') and available_at<now()-interval '10 minutes'));"|Select-Object -Last 1).Trim().Split('|')
      if($LASTEXITCODE-ne 0-or$remaining.Count-ne 2-or@($remaining|Where-Object{$_-notmatch'^\d+$'}).Count-gt 0-or$task.State-ne'Running'-or(Get-ExactWorkerProcessCount $notificationPattern)-ne 1){throw 'notification recovery verification failed'}
      if(([int]$remaining[0]+[int]$remaining[1])-eq 0){
        Send-PrivateAlert 'Family Documents — automatic recovery succeeded. The reminder notification worker was restarted and due-day delivery is healthy. No reminder or recipient content is included.' 'notification_worker_recovered'
        $notificationDown=0;$dueDayMissing=0;$overdueNotifications=0
      }
    }catch{Write-Output 'notification_automatic_recovery=failed'}
  }
}
if(($retrying+$dead+$locked+$overdue+$staleScans+$orphanedBody+$classifierDown+$scannerDown+$dueDayMissing+$overdueNotifications+$notificationDown)-eq 0){
  if(Test-Path -LiteralPath $statePath){
    $priorSignature=''
    try{$priorSignature=(Get-Content -Raw -LiteralPath $statePath|ConvertFrom-Json).signature}catch{}
    if($priorSignature-notin@('attachment_scanner_recovered','classifier_recovered','notification_worker_recovered')){
      Send-PrivateAlert 'Family Documents — inbound email processing has recovered. The classification queue is healthy.' 'recovered'
      if(-not $DryRun -and (Test-Path -LiteralPath $statePath)){Remove-Item -LiteralPath $statePath -Force}
    }
  }
  Write-Output 'health=ok';exit 0
}
$signature="retrying=$retrying;dead=$dead;locked=$locked;overdue=$overdue;stale_scans=$staleScans;orphaned_body=$orphanedBody;classifier_down=$classifierDown;scanner_down=$scannerDown;due_day_missing=$dueDayMissing;overdue_notifications=$overdueNotifications;notification_down=$notificationDown"
$message=@"
Family Documents — inbound email warning

Messages retrying after repeated failures: $retrying
Dead-lettered jobs: $dead
Workers locked over 10 minutes: $locked
Jobs overdue over 10 minutes: $overdue
Oldest active job: $oldest minute(s)
Attachments waiting for scanning over 2 minutes: $staleScans
Oldest attachment waiting for scanning: $oldestScan minute(s)
Allowed body-only emails missing a classification job: $orphanedBody
Classifier watcher unhealthy or process count not one: $classifierDown (processes: $classifierProcessCount)
Attachment scanner unhealthy or process count not one: $scannerDown (processes: $scannerProcessCount)
Due-day reminders missing notification records after 08:10 NZ: $dueDayMissing
Due-day notification deliveries overdue over 10 minutes: $overdueNotifications
Reminder notification watcher unhealthy or process count not one: $notificationDown (processes: $notificationProcessCount)
Classifier restart safety limit reached: $classifierRecoveryLimited
Attachment scanner restart safety limit reached: $scannerRecoveryLimited
Reminder notification restart safety limit reached: $notificationRecoveryLimited

No sender, subject, filename or document content is included.
"@
Send-PrivateAlert $message $signature
