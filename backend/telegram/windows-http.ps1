$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
  $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
  $uri = [Uri]$request.url
  if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'api.telegram.org' -or $uri.Port -ne 443 -or $uri.UserInfo) { throw 'Invalid endpoint' }
  Add-Type -AssemblyName System.Net.Http
  $handler = New-Object System.Net.Http.HttpClientHandler
  $handler.AllowAutoRedirect = $false
  $client = New-Object System.Net.Http.HttpClient($handler)
  $client.Timeout = [TimeSpan]::FromMilliseconds([int]$request.timeout)
  $method = New-Object System.Net.Http.HttpMethod([string]$request.method)
  $message = New-Object System.Net.Http.HttpRequestMessage($method, $uri)
  if ($request.method -eq 'POST') {
    $message.Content = New-Object System.Net.Http.StringContent([string]$request.body, [Text.Encoding]::UTF8, 'application/json')
  }
  $response = $client.SendAsync($message, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
  $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
  $buffer = New-Object byte[] 65536
  $memory = New-Object IO.MemoryStream
  while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
    if ($memory.Length + $count -gt [int]$request.maxBytes) { throw 'Response limit exceeded' }
    $memory.Write($buffer, 0, $count)
  }
  @{status=[int]$response.StatusCode; body=[Convert]::ToBase64String($memory.ToArray())} | ConvertTo-Json -Compress
} catch {
  # Exception text may contain the bot token URL. Never emit it.
  [Console]::Out.WriteLine('{"error":"telegram_windows_https_failed"}')
  exit 1
} finally {
  if ($stream) { $stream.Dispose() }
  if ($memory) { $memory.Dispose() }
  if ($response) { $response.Dispose() }
  if ($message) { $message.Dispose() }
  if ($client) { $client.Dispose() }
}
