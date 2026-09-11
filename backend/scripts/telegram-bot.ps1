param(
  [Parameter(Mandatory=$true)][ValidateSet('get-me','set-webhook','webhook-info','delete-webhook','set-commands')][string]$Action,
  [string]$WebhookUrl
)
$ErrorActionPreference='Stop'
$token=$env:TELEGRAM_BOT_TOKEN
if([string]::IsNullOrWhiteSpace($token)){throw 'TELEGRAM_BOT_TOKEN is required'}
$base="https://api.telegram.org/bot$token"
switch($Action){
  'get-me' {$result=Invoke-RestMethod -Method Post -Uri "$base/getMe"}
  'set-webhook' {
    if([string]::IsNullOrWhiteSpace($WebhookUrl) -or -not $WebhookUrl.StartsWith('https://')){throw 'A public HTTPS WebhookUrl is required'}
    if([string]::IsNullOrWhiteSpace($env:TELEGRAM_WEBHOOK_SECRET)){throw 'TELEGRAM_WEBHOOK_SECRET is required'}
    $result=Invoke-RestMethod -Method Post -Uri "$base/setWebhook" -ContentType 'application/json' -Body (@{url=$WebhookUrl;secret_token=$env:TELEGRAM_WEBHOOK_SECRET;allowed_updates=@('message','callback_query');drop_pending_updates=$false}|ConvertTo-Json)
  }
  'webhook-info' {$result=Invoke-RestMethod -Method Post -Uri "$base/getWebhookInfo"}
  'delete-webhook' {$result=Invoke-RestMethod -Method Post -Uri "$base/deleteWebhook" -ContentType 'application/json' -Body (@{drop_pending_updates=$false}|ConvertTo-Json)}
  'set-commands' {
    $commands=@(@{command='start';description='Connect or show welcome'},@{command='help';description='Supported FamilyDocuments actions'},@{command='new';description='Start a new conversation'},@{command='cancel';description='Cancel the pending choice'},@{command='status';description='Show active Family and processing'},@{command='family';description='Choose an authorised Family'},@{command='disconnect';description='Disconnect after confirmation'})
    $result=Invoke-RestMethod -Method Post -Uri "$base/setMyCommands" -ContentType 'application/json' -Body (@{commands=$commands}|ConvertTo-Json -Depth 4)
  }
}
if(-not $result.ok){throw 'Telegram Bot API operation failed'}
[pscustomobject]@{ok=$true;action=$Action}
