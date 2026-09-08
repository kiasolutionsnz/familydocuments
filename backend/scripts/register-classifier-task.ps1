$ErrorActionPreference = 'Stop'
$taskName = 'Kia Family Documents Classifier'
$projectRoot = Split-Path -Parent $PSScriptRoot
$classifier = Join-Path $projectRoot 'email-ingestion\classifier.mjs'
if (-not (Test-Path -LiteralPath $classifier)) { throw "Classifier not found: $classifier" }
$node = (Get-Command node -ErrorAction Stop).Source
$action = New-ScheduledTaskAction -Execute $node -Argument "`"$classifier`" --watch" -WorkingDirectory $projectRoot
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Runs the confirmation-gated Family Documents local email classifier.' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Get-ScheduledTask -TaskName $taskName | Select-Object TaskName,State
