$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
& node document-analysis/worker.mjs --watch
exit $LASTEXITCODE
