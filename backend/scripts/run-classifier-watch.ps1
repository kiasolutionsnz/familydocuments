$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$node = (Get-Command node -ErrorAction Stop).Source
& $node '.\email-ingestion\classifier.mjs' '--watch'
exit $LASTEXITCODE
