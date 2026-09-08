$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$node = (Get-Command node -ErrorAction Stop).Source
& $node '.\email-ingestion\attachment-scanner.mjs' '--watch'
exit $LASTEXITCODE
