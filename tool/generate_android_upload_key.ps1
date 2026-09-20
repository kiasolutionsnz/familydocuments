param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$BackupRoot,

    [Parameter(Mandatory = $true)]
    [string]$KeytoolPath
)

$ErrorActionPreference = 'Stop'

function New-StrongSecret {
    param([int]$ByteCount = 32)

    $bytes = New-Object byte[] $ByteCount
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$androidRoot = Join-Path $ProjectRoot 'android'
$keystorePath = Join-Path $androidRoot 'app\familydocuments-upload.jks'
$propertiesPath = Join-Path $androidRoot 'key.properties'
$backupPath = Join-Path $BackupRoot 'Android-Play-Upload-Key'
$backupKeystorePath = Join-Path $backupPath 'familydocuments-upload.jks'
$protectedPropertiesPath = Join-Path $backupPath 'key.properties.dpapi'
$recoveryNotePath = Join-Path $backupPath 'RECOVERY.txt'

if ((Test-Path -LiteralPath $keystorePath) -or (Test-Path -LiteralPath $propertiesPath)) {
    throw 'Android upload signing material already exists. Refusing to overwrite it.'
}

New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

$storePassword = New-StrongSecret
$keyPassword = $storePassword
$alias = 'familydocuments-upload'

try {
    & $KeytoolPath `
        -genkeypair `
        -v `
        -keystore $keystorePath `
        -storetype PKCS12 `
        -storepass $storePassword `
        -keypass $keyPassword `
        -alias $alias `
        -keyalg RSA `
        -keysize 4096 `
        -validity 10000 `
        -dname 'CN=Inder, OU=FamilyDocuments, O=FamilyDocuments, L=Auckland, ST=Auckland, C=NZ' | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "keytool failed with exit code $LASTEXITCODE"
    }

    $properties = @(
        "storePassword=$storePassword"
        "keyPassword=$keyPassword"
        "keyAlias=$alias"
        'storeFile=familydocuments-upload.jks'
    ) -join [Environment]::NewLine

    [IO.File]::WriteAllText($propertiesPath, $properties, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $keystorePath -Destination $backupKeystorePath -Force

    $plainBytes = [Text.Encoding]::UTF8.GetBytes($properties)
    $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
        $plainBytes,
        $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [IO.File]::WriteAllBytes($protectedPropertiesPath, $protectedBytes)

    $recoveryNote = @'
FamilyDocuments Android Google Play upload key

The .jks file is encrypted by a strong generated password.
The key.properties.dpapi file contains the matching configuration encrypted for
the Windows user profile that created it. It is not plaintext and cannot be
decrypted under another Windows account or on another computer without that
profile's Windows data-protection keys.

Keep this folder in OneDrive. Before moving release signing to another machine,
decrypt and transfer the signing material from the original Windows profile, or
use Google Play App Signing's upload-key reset process.

Never commit the .jks file or key.properties to Git.
'@
    [IO.File]::WriteAllText($recoveryNotePath, $recoveryNote, [Text.UTF8Encoding]::new($false))
}
catch {
    Remove-Item -LiteralPath $keystorePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $propertiesPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupKeystorePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $protectedPropertiesPath -Force -ErrorAction SilentlyContinue
    throw
}
finally {
    $storePassword = $null
    $keyPassword = $null
    $properties = $null
}

[pscustomobject]@{
    Keystore = $keystorePath
    Properties = $propertiesPath
    Backup = $backupPath
}
