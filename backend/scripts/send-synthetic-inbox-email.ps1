param(
  [Parameter(Mandatory=$true)][string]$To,
  [string]$Subject = 'Synthetic household document',
  [string]$Body = 'Synthetic local test message. No real family information is included.',
  [string[]]$AttachmentPath
)
$ErrorActionPreference = 'Stop'
if ($To -notmatch '^family-[0-9a-f]{24}@family-passport[.]local$') {
  throw 'To must be a generated local Family Passport inbox address.'
}
$message = [System.Net.Mail.MailMessage]::new()
$client = [System.Net.Mail.SmtpClient]::new('127.0.0.1', 55325)
try {
  $message.From = 'synthetic-sender@family-passport.test'
  [void]$message.To.Add($To)
  $message.Subject = $Subject
  $message.Body = $Body
  foreach ($path in $AttachmentPath) {
    $resolved = (Resolve-Path -LiteralPath $path).Path
    $file = Get-Item -LiteralPath $resolved
    if ($file.Name -notmatch '^synthetic-.*[.]pdf$' -or $file.Length -gt 1MB) { throw 'Only synthetic-*.pdf fixtures up to 1 MB are allowed in this local test helper.' }
    [void]$message.Attachments.Add([System.Net.Mail.Attachment]::new($resolved, 'application/pdf'))
  }
  $client.Send($message)
  Write-Host "Synthetic email delivered to local Mailpit for $To"
} finally {
  $message.Dispose()
  $client.Dispose()
}
