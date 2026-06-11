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
# We pin 2.24-101-g897c7ad specifically because it is the most recent
# 2.24 revision the nssm.cc/release/ zip has ever published and is what
# every modern packaging system (chocolatey, scoop) consumes today.
#
# Mirror policy, in priority order:
#   1. nssm.cc/ci - the upstream nssm project itself. Currently returns
#      503 from its nginx for `nssm.cc/release/*`; `nssm.cc/ci/*` is
#      usually up but not always.
#   2. GitHub raw from Bane007/NSSM---the-Non-Sucking-Service-Manager -
#      a community repo that mirrors the exact same nssm-2.24-101 zip
#      used by upstream packaging. Served by GitHub's CDN so it is the
#      most reliable of the three.
#   3. archive.org Wayback Machine snapshot of nssm.cc/ci, kept as a
#      last-resort fallback. NB: archive.org does NOT serve the raw zip
#      bytes - it wraps the response in an HTML page - so it is only
#      useful as a connectivity sanity check, not as a real source. We
#      still try it; if it is the only thing that worked the resulting
#      `tar -xf` will fail with "Unrecognized archive format" and the
#      outer catch surfaces a clear error.
$NssmUrls = @(
    'https://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip',
    'https://raw.githubusercontent.com/Bane007/NSSM---the-Non-Sucking-Service-Manager/main/nssm-2.24-101-g897c7ad.zip',
    'https://web.archive.org/web/2024/https://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip'
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

# nssm.cc's nginx still negotiates TLS 1.0/1.1; force 1.2 so this works
# on stock PowerShell 5.1.
[System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.ServicePointManager]::SecurityProtocol -bor `
    [System.Net.SecurityProtocolType]::Tls12

if (-not (Test-Path -LiteralPath $ZipPath)) {
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
    throw "Failed to extract $ZipPath (is the downloaded file actually a zip? See mirror notes in the script header)"
}

$Source64 = Join-Path $ExtractDir 'win64\nssm.exe'
if (-not (Test-Path -LiteralPath $Source64)) {
    throw "Expected nssm.exe not found at $Source64"
}

Copy-Item -LiteralPath $Source64 -Destination $NssmExePath -Force
Write-Output "Generated $NssmExePath"
