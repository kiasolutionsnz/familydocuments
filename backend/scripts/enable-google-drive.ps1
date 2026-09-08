$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path;$envFile=Join-Path $root '.env.local';if(-not(Test-Path -LiteralPath $envFile)){throw '.env.local is required'}
$values=@{};Get-Content -LiteralPath $envFile|ForEach-Object{if($_ -match '^([A-Z0-9_]+)=(.*)$'){$values[$matches[1]]=$matches[2].Trim()}}
foreach($key in @('GOOGLE_DRIVE_CLIENT_ID','GOOGLE_DRIVE_API_KEY','GOOGLE_DRIVE_APP_ID')){if([string]::IsNullOrWhiteSpace($values[$key])){throw "$key is not configured"}}
foreach($value in @($values['GOOGLE_DRIVE_CLIENT_ID'],$values['GOOGLE_DRIVE_API_KEY'],$values['GOOGLE_DRIVE_APP_ID'])){if($value -notmatch '^[A-Za-z0-9._-]+$'){throw 'Google Drive configuration contains invalid characters'}}
$frontendRoot=(Resolve-Path (Join-Path $root '..\frontend\frontend')).Path
if(-not(Test-Path -LiteralPath (Join-Path $frontendRoot '.openai\hosting.json'))){throw 'Family Documents Sites frontend was not found'}
$target=Join-Path $frontendRoot 'public\prototype\google-drive-config.local.js';$content="window.familyPassportGoogleDriveConfig=Object.freeze({clientId:`"$($values['GOOGLE_DRIVE_CLIENT_ID'])`",apiKey:`"$($values['GOOGLE_DRIVE_API_KEY'])`",appId:`"$($values['GOOGLE_DRIVE_APP_ID'])`"});";Set-Content -LiteralPath $target -Value $content -Encoding utf8NoBOM
Write-Host 'Google Drive folder-storage browser configuration generated. Rebuild and deploy the frontend, then test with a dedicated synthetic folder.'
