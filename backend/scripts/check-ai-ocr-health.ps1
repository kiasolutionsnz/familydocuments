[CmdletBinding()]
param(
  [switch]$DryRun,
  [ValidateSet('none','llm','ocr')][string]$SimulateFailure='none'
)
$ErrorActionPreference='Stop'
$docker='C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$ollamaApp='C:\Users\Inder\AppData\Local\Programs\Ollama\ollama app.exe'
$monitoring='C:\Users\Inder\My Codex Apps\platform\monitoring'
$tokenPath=Join-Path $monitoring 'secrets\telegram-bot-token'
$chatPath=Join-Path $monitoring 'secrets\telegram-chat-id'
$runtime=Join-Path $monitoring 'runtime'

function Read-State([string]$Name){
  $path=Join-Path $runtime "familydocuments-$Name-health.json"
  if(Test-Path -LiteralPath $path){try{return Get-Content -Raw -LiteralPath $path|ConvertFrom-Json}catch{}}
  return [pscustomobject]@{status='unknown';last_alert_at=$null}
}
function Write-State([string]$Name,[string]$Status,[object]$LastAlertAt){
  if($DryRun){return}
  if(-not(Test-Path -LiteralPath $runtime)){New-Item -ItemType Directory -Path $runtime|Out-Null}
  @{status=$Status;last_alert_at=$LastAlertAt;checked_at=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $runtime "familydocuments-$Name-health.json") -Encoding utf8
}
function Send-Alert([string]$Message){
  if($DryRun){Write-Output "telegram_dry_run=$Message";return}
  if(-not(Test-Path -LiteralPath $tokenPath)-or-not(Test-Path -LiteralPath $chatPath)){throw 'Telegram secret files are unavailable.'}
  $token=(Get-Content -Raw -LiteralPath $tokenPath).Trim();$chat=(Get-Content -Raw -LiteralPath $chatPath).Trim()
  Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$token/sendMessage" -Body @{chat_id=$chat;text=$Message;disable_web_page_preview='true'} -TimeoutSec 30|Out-Null
}
function Test-Llm([switch]$Inference){
  if($SimulateFailure-eq'llm'){return $false}
  try{
    $version=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/version' -TimeoutSec 8
    $tags=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 8
    if(-not $version.version-or-not($tags.models.name-contains'qwen3:4b')){return $false}
    if($Inference){
      $payload=@{model='qwen3:4b';stream=$false;think=$false;keep_alive=-1;format='json';messages=@(@{role='user';content='Return JSON only: {"status":"ok"}'})}|ConvertTo-Json -Depth 6
      $reply=Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:11434/api/chat' -ContentType 'application/json' -Body $payload -TimeoutSec 90
      if(-not $reply.message.content){return $false}
    }
    return $true
  }catch{return $false}
}
function Test-Ocr{
  if($SimulateFailure-eq'ocr'){return $false}
  try{$response=Invoke-RestMethod -Uri 'http://127.0.0.1:55323/health' -TimeoutSec 8;return $response.status-eq'ok'}catch{return $false}
}
function Recover-Llm{
  if($DryRun){Write-Output 'recovery_dry_run=restart_ollama';return $false}
  Get-CimInstance Win32_Process|Where-Object{$_.Name-in@('ollama.exe','ollama app.exe')}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
  Start-Process -FilePath $ollamaApp -WindowStyle Hidden
  for($i=0;$i-lt 12;$i++){Start-Sleep -Seconds 5;if(Test-Llm){return (Test-Llm -Inference)}}
  return $false
}
function Recover-Ocr{
  if($DryRun){Write-Output 'recovery_dry_run=restart_familydocuments_ocr';return $false}
  & $docker restart family-passport-supabase-ocr-1|Out-Null
  if($LASTEXITCODE-ne 0){return $false}
  for($i=0;$i-lt 12;$i++){Start-Sleep -Seconds 5;if(Test-Ocr){return $true}}
  return $false
}
function Check-Dependency([string]$Name,[string]$Label,[scriptblock]$Probe,[scriptblock]$Recover){
  $state=Read-State $Name;$healthy=& $Probe
  if($healthy){
    if($state.status-eq'failed'){Send-Alert "Family Documents - $Label has recovered and passed its health check."}
    Write-State $Name 'healthy' $state.last_alert_at
    Write-Output "$Name=healthy";return
  }
  $recovered=& $Recover
  $now=[datetime]::UtcNow;$last=if($state.last_alert_at){([datetime]$state.last_alert_at).ToUniversalTime()}else{[datetime]::MinValue}
  $mayAlert=$now-$last-gt[TimeSpan]::FromHours(4)
  if($recovered){
    if($mayAlert){Send-Alert "Family Documents - $Label was unavailable. Automatic recovery succeeded and the service passed its verification check.";$last=$now}
    Write-State $Name 'healthy' $last.ToString('o');Write-Output "$Name=recovered";return
  }
  if($mayAlert){Send-Alert "Family Documents alert - $Label is unavailable and automatic recovery did not succeed. Manual attention is required. No document content is included.";$last=$now}
  Write-State $Name 'failed' $last.ToString('o');Write-Output "$Name=failed"
}

Check-Dependency 'llm' 'local AI/LLM service' {Test-Llm -Inference} {Recover-Llm}
Check-Dependency 'ocr' 'OCR service' {Test-Ocr} {Recover-Ocr}
