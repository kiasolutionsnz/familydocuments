$ErrorActionPreference = 'Stop'
$taskName = 'Kia Family Documents Analysis'
$projectRoot = Split-Path -Parent $PSScriptRoot
$worker = Join-Path $projectRoot 'document-analysis\worker.mjs'
if (-not (Test-Path -LiteralPath $worker)) { throw "Document analysis worker not found: $worker" }
$node = (Get-Command node -ErrorAction Stop).Source
$action = New-ScheduledTaskAction -Execute $node -Argument "`"$worker`" --watch" -WorkingDirectory $projectRoot
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Runs durable Family Documents OCR and classification jobs.' -Force | Out-Null
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName,State
