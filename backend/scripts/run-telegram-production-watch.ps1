param([switch]$Once)
$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$productionConfig = 'C:\Users\Inder\My Codex Apps\familydocuments\backend\.telegram.local'
if (-not (Test-Path -LiteralPath $productionConfig)) {
  throw 'Production Telegram configuration is missing.'
}
foreach ($line in [IO.File]::ReadAllLines($productionConfig)) {
  if ($line -match '^(TELEGRAM_BOT_IDENTITY|TELEGRAM_BOT_USERNAME|TELEGRAM_BOT_TOKEN|TELEGRAM_WEBHOOK_SECRET)=(.*)$') {
    [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
  }
}
$docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$gateway = 'family-passport-supabase-inbound-gateway-1'
$gatewayEnv = & $docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' $gateway
if ($LASTEXITCODE -ne 0) { throw 'Production gateway is unavailable.' }
$secret = $gatewayEnv | Where-Object { $_ -like 'GOTRUE_JWT_SECRET=*' } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($secret)) { throw 'Production service credential is unavailable.' }
$env:GOTRUE_JWT_SECRET = $secret.Substring('GOTRUE_JWT_SECRET='.Length)
$env:FP_API_URL = 'http://127.0.0.1:55322'
$env:FP_GATEWAY_URL = 'http://127.0.0.1:55327'
$env:TELEGRAM_HTTP_TRANSPORT = 'windows'
Set-Location -LiteralPath $sourceRoot
if ($Once) {
  & node '.\telegram\worker.mjs'
} else {
  & node '.\telegram\worker.mjs' --watch
}
exit $LASTEXITCODE
