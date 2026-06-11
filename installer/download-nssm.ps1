# Download nssm.exe (64-bit) used by the installer to wrap qmt-gateway as a
# Windows service. nssm 2.24 is released under the public-domain-equivalent
# license shown at https://nssm.cc/license and is distributed as a single
# native exe per architecture.
#
# This script runs at build time from installer.nsi's !system directive,
# alongside generate-requirements.py and generate-bitmaps.ps1. It downloads
# the upstream zip once, extracts the 64-bit binary, and caches it as
# installer\nssm.exe so subsequent builds are offline-friendly.

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$NssmVersion = '2.24-101-g897c7ad'
# nssm.cc/release/nssm-2.24.zip currently returns 503 from the upstream nginx;
# the CI build at nssm.cc/ci/<rev>.zip is the same family (2.24 + post-release
# fixes) and is what every modern packaging system - chocolatey, scoop -
# pulls today. archive.org is kept as a last-resort fallback.
$NssmUrls = @(
    "https://nssm.cc/ci/nssm-$NssmVersion.zip",
    "https://web.archive.org/web/2024/https://nssm.cc/ci/nssm-$NssmVersion.zip"
)
$NssmExePath = Join-Path $ScriptDir 'nssm.exe'
$DownloadDir = Join-Path $ScriptDir '.nssm-cache'
$ZipPath     = Join-Path $DownloadDir "nssm-$NssmVersion.zip"
$ExtractDir  = Join-Path $DownloadDir "nssm-$NssmVersion"

if (Test-Path -LiteralPath $NssmExePath) {
    Write-Output "nssm.exe already present at $NssmExePath - skipping download"
    exit 0
}

New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null

if (-not (Test-Path -LiteralPath $ZipPath)) {
    # nssm.cc serves the zip over HTTPS but with an older TLS preference; force
    # TLS 1.2 so this works on stock PowerShell 5.1.
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor `
        [System.Net.SecurityProtocolType]::Tls12

    $downloaded = $false
    foreach ($url in $NssmUrls) {
        Write-Output "Downloading $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $ZipPath -UseBasicParsing -TimeoutSec 60
            $downloaded = $true
            break
        } catch {
            Write-Output "  failed: $($_.Exception.Message)"
            if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
        }
    }

    if (-not $downloaded) {
        throw "Failed to download nssm from any mirror; checked: $($NssmUrls -join ', ')"
    }
}

if (Test-Path -LiteralPath $ExtractDir) {
    Remove-Item -LiteralPath $ExtractDir -Recurse -Force
}

# tar.exe ships with Windows 10 1803+ and handles zip reliably; we use the
# same approach as installer.nsi's python-embed.zip extraction.
& cmd.exe /c "tar -xf `"$ZipPath`" -C `"$DownloadDir`""
if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract $ZipPath"
}

$Source64 = Join-Path $ExtractDir 'win64\nssm.exe'
if (-not (Test-Path -LiteralPath $Source64)) {
    throw "Expected nssm.exe not found at $Source64"
}

Copy-Item -LiteralPath $Source64 -Destination $NssmExePath -Force
Write-Output "Generated $NssmExePath"
