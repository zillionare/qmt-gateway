param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Uninstall')]
    [string]$Stage
)

# Install or uninstall the QMT Gateway Windows service. Wraps nssm.exe so
# the embedded python is supervised: starts at boot, restarts on crash,
# captures stdout / stderr to rotating log files. Called from
# installer.nsi via nsExec::ExecToLog, mirroring the contract used by
# install-python.ps1:
#  - InstallLocation is read from HKLM\SOFTWARE\qmt-gateway so NSIS does
#    not have to pass CJK paths on the command line.
#  - All progress is appended to install.log next to the installer's own
#    log.
#  - Non-zero exit aborts the NSIS section via AbortOnExecFailure.
#
# The service's AppPath is start-service.bat, a small wrapper that sets
# QMT_GATEWAY_HOME / PYTHONPATH / PYTHONUTF8 / PATH and then execs
# python -m qmt_gateway. Going via a .bat is the only way we found to
# deliver that multi-line environment block to the embedded python
# reliably - nssm 2.24's AppEnvironmentExtra has quoting / encoding
# issues under PowerShell 5.1 and on CJK install paths (#66).

$ErrorActionPreference = 'Stop'

$ServiceName        = 'QuantideGateway'
$ServiceDisplayName = '匡醍 QMT 交易网关'
$ServiceDescription = '后台运行 qmt-gateway，开机自启并在异常退出时自动重启。'
$InstallLogName     = 'install.log'

$StateRegistryPaths = @(
    'HKLM:\SOFTWARE\qmt-gateway',
    'HKLM:\SOFTWARE\WOW6432Node\qmt-gateway'
)

function Get-InstallLocation {
    foreach ($path in $StateRegistryPaths) {
        try {
            $value = (Get-ItemProperty -LiteralPath $path -ErrorAction Stop).InstallLocation
            if ($value) {
                return $value
            }
        } catch {
        }
    }

    throw 'InstallLocation registry value was not found'
}

$InstallDir = Get-InstallLocation
$PythonDir  = Join-Path $InstallDir 'python'
$PythonExe  = Join-Path $PythonDir 'python.exe'
$NssmExe    = Join-Path $InstallDir 'nssm.exe'
$LogsDir    = Join-Path $InstallDir 'logs'
$InstallLog = Join-Path $InstallDir $InstallLogName

function Add-InstallerLogLine {
    param([string]$Line)
    Add-Content -LiteralPath $InstallLog -Encoding UTF8 -Value $Line
}

function Invoke-Nssm {
    param([string[]]$Arguments)

    $outputPath = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    $scriptPath = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName() + '.cmd')

    # Write a tiny .cmd wrapper that invokes nssm and echoes a sentinel
    # line carrying the exit code. Going via a real .cmd file sidesteps
    # PowerShell's awkward quoting of the cmd /c command line for paths
    # with spaces, and makes exit-code reporting deterministic (cmd.exe
    # $ERRORLEVEL survives a verbatim call whereas PowerShell's
    # $LASTEXITCODE is clobbered by intervening cmdlets).
    $quotedArgs = ($Arguments | ForEach-Object { '"{0}"' -f $_ }) -join ' '
    $nl        = [Environment]::NewLine
    $scriptBody = '@echo off' + $nl + '"' + $NssmExe + '" ' + $quotedArgs + $nl + 'echo NSSMEXIT=%ERRORLEVEL%' + $nl
    [System.IO.File]::WriteAllText($scriptPath, $scriptBody, [System.Text.ASCIIEncoding]::new())

    & cmd.exe /c $scriptPath > $outputPath 2>&1
    $raw = Get-Content -LiteralPath $outputPath
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue

    $exitCode = 0
    foreach ($line in $raw) {
        if ($line -match '^NSSMEXIT=(\-?\d+)\s*$') {
            $exitCode = [int]$Matches[1]
            continue
        }
        # Out-Default only - writing to the pipeline would cause
        # `$x = Invoke-Nssm ...` to capture the nssm output strings
        # instead of the integer return value.
        $line | Out-Default
        Add-InstallerLogLine ('  ' + $line)
    }
    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue

    return $exitCode
}

function Test-ServiceExists {
    return [bool](Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
}

function Set-ServiceMetadata {
    # Write DisplayName / Description (REG_SZ, UTF-16) directly into the
    # service's registry key. nssm's `set DisplayName|Description` goes
    # through argv -> MultiByteToWideChar(CP_ACP) -> RegSetValueExW and
    # corrupts CJK characters when the host's ANSI code page is not a
    # CJK CP (eg. 437 on the GitHub runner). The .NET Registry API
    # always writes the REG_SZ as UTF-16LE so services.msc displays the
    # string correctly regardless of the host's ANSI code page.
    Add-InstallerLogLine ('Service: write DisplayName / Description as UTF-16 REG_SZ: ' + $ServiceDisplayName)
    $key = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        $env:COMPUTERNAME
    )
    $sub = $null
    try {
        $sub = $key.OpenSubKey(
            "SYSTEM\CurrentControlSet\Services\$ServiceName",
            $true
        )
        if ($null -eq $sub) {
            throw "service registry key not found"
        }
        $sub.SetValue('DisplayName', $ServiceDisplayName, [Microsoft.Win32.RegistryValueKind]::String)
        $sub.SetValue('Description', $ServiceDescription, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        if ($sub) { $sub.Dispose() }
        $key.Dispose()
    }
}

function Stop-ServiceIfRunning {
    if (-not (Test-ServiceExists)) { return }
    try {
        $svc = Get-Service -Name $ServiceName -ErrorAction Stop
        if ($svc.Status -ne 'Stopped') {
            Add-InstallerLogLine ('Service: stopping ' + $ServiceName)
            $null = Invoke-Nssm @('stop', $ServiceName)
            # nssm stop returns when the SCM acknowledges the stop, but
            # the process may take a moment to actually exit.
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 250
                $svc.Refresh()
                if ($svc.Status -eq 'Stopped') { break }
            }
        }
    } catch {
        Add-InstallerLogLine ('Service: stop error: ' + $_.Exception.Message)
    }
}

function Invoke-InstallStage {
    Add-InstallerLogLine '==== Service: install ===='
    Add-InstallerLogLine ('INSTDIR=' + $InstallDir)
    Add-InstallerLogLine ('PYTHON_EXE=' + $PythonExe)
    Add-InstallerLogLine ('NSSM_EXE=' + $NssmExe)

    if (-not (Test-Path -LiteralPath $NssmExe)) {
        throw "nssm.exe not found at $NssmExe"
    }
    # python.exe is only required for actually running the gateway. The
    # service metadata + recovery policy can be installed without it; that
    # is useful for offline / smoke-test scenarios where we want to verify
    # the service scaffolding without a full NSIS run.
    if (-not (Test-Path -LiteralPath $PythonExe)) {
        Add-InstallerLogLine ('Service: WARNING - python.exe missing at ' + $PythonExe + '; continuing without it')
    }

    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null

    $stdoutLog = Join-Path $LogsDir 'service.out.log'
    $stderrLog = Join-Path $LogsDir 'service.err.log'
    $wrapper   = Join-Path $InstallDir 'start-service.bat'

    if (-not (Test-Path -LiteralPath $wrapper)) {
        throw "start-service.bat not found at $wrapper"
    }

    # If the service already exists (re-install / upgrade), stop it and
    # remove it; nssm refuses to re-install an existing service.
    if (Test-ServiceExists) {
        Stop-ServiceIfRunning
        Add-InstallerLogLine ('Service: removing existing ' + $ServiceName)
        $null = Invoke-Nssm @('remove', $ServiceName, 'confirm')
        Start-Sleep -Milliseconds 500
    }

    Add-InstallerLogLine ('Service: install ' + $ServiceName)
    $exit = Invoke-Nssm @('install', $ServiceName, $wrapper)
    if ($exit -ne 0) { throw "nssm install failed with exit code $exit" }

    # Service metadata + working directory. nssm `set` calls in this
    # block have all been verified end-to-end on Windows 10 22H2 /
    # nssm 2.24-101; do not add new keys here without also testing them.
    # DisplayName / Description are written directly to the registry
    # (REG_SZ, UTF-16) below the nssm `set` block - see Set-ServiceMetadata.
    $null = Invoke-Nssm @('set', $ServiceName, 'AppDirectory', $InstallDir)
    $null = Invoke-Nssm @('set', $ServiceName, 'Start',        'SERVICE_AUTO_START')

    # stdout / stderr capture with rotation. The main diagnostic
    # surface when the service fails to come up on boot.
    $null = Invoke-Nssm @('set', $ServiceName, 'AppStdout',       $stdoutLog)
    $null = Invoke-Nssm @('set', $ServiceName, 'AppStderr',       $stderrLog)
    $null = Invoke-Nssm @('set', $ServiceName, 'AppRotateFiles',  '1')
    $null = Invoke-Nssm @('set', $ServiceName, 'AppRotateOnline', '1')
    $null = Invoke-Nssm @('set', $ServiceName, 'AppRotateBytes',  '10485760')

    # Restart-on-crash supervision. Exit 0 still triggers a restart so
    # a mis-behaving graceful shutdown does not leave the gateway down.
    $null = Invoke-Nssm @('set', $ServiceName, 'AppExit',         'Default', 'Restart')
    $null = Invoke-Nssm @('set', $ServiceName, 'AppRestartDelay', '5000')
    $null = Invoke-Nssm @('set', $ServiceName, 'AppThrottle',     '5000')

    # DisplayName / Description: write REG_SZ (UTF-16) directly. nssm's
    # `set DisplayName ...` goes through MultiByteToWideChar(CP_ACP) and
    # when the system code page is not a CJK CP (eg. CI runner is 437),
    # Chinese characters turn into '?' (0x3F) in the registry. The .NET
    # Registry API always writes UTF-16LE for REG_SZ, which is what
    # services.msc expects to see. Done before `start` so it survives even
    # if the first start fails (eg. python not yet on PATH).
    Set-ServiceMetadata

    # Recovery policy: on first / second / subsequent crash, restart the
    # service after 60 s. We use sc.exe rather than nssm because nssm's
    # `set FailureActions` writes the registry value as MBCS bytes and
    # services.msc shows the action label as mojibake on non-UTF8 system
    # code pages; sc.exe uses ChangeServiceConfig2 and writes a proper
    # UTF-16 REG_SZ / binary structure.
    Add-InstallerLogLine 'Service: configure recovery policy (sc.exe failure)'
    $failureOutput = & cmd.exe /c 'sc failure QuantideGateway reset= 0 actions= restart/60000/restart/60000/restart/60000' 2>&1
    foreach ($line in $failureOutput) {
        $line | Out-Default
        Add-InstallerLogLine ('  ' + $line)
    }
    if ($LASTEXITCODE -ne 0) {
        Add-InstallerLogLine ('Service: WARNING - sc.exe failure returned ' + $LASTEXITCODE)
    }

    Add-InstallerLogLine ('Service: starting ' + $ServiceName)
    $exit = Invoke-Nssm @('start', $ServiceName)
    if ($exit -ne 0) {
        # nssm start can return non-zero while the service is still in
        # StartPending; if the SCM eventually reports Running (or
        # StartPending), treat that as success.
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and ($svc.Status -eq 'Running' -or $svc.Status -eq 'StartPending')) {
            Add-InstallerLogLine ('  (service status is ' + $svc.Status + ' - treating as success)')
            $exit = 0
        }
    }
    if ($exit -ne 0) { throw "nssm start failed with exit code $exit" }

    Add-InstallerLogLine 'Service: install OK'
}

function Invoke-UninstallStage {
    Add-InstallerLogLine '==== Service: uninstall ===='
    if (-not (Test-Path -LiteralPath $NssmExe)) {
        Add-InstallerLogLine ('Service: nssm.exe missing at ' + $NssmExe + ' - using sc.exe fallback')
        if (Test-ServiceExists) {
            & sc.exe stop   $ServiceName | Out-Null
            Start-Sleep -Milliseconds 500
            & sc.exe delete $ServiceName | Out-Null
        }
        return
    }

    if (Test-ServiceExists) {
        Stop-ServiceIfRunning
        Add-InstallerLogLine ('Service: removing ' + $ServiceName)
        $null = Invoke-Nssm @('remove', $ServiceName, 'confirm')
    } else {
        Add-InstallerLogLine ('Service: ' + $ServiceName + ' not installed')
    }

    Add-InstallerLogLine 'Service: uninstall OK'
}

try {
    if (-not (Test-Path -LiteralPath $InstallLog)) {
        Set-Content -LiteralPath $InstallLog -Encoding UTF8 -Value @()
    }

    switch ($Stage) {
        'Install'   { Invoke-InstallStage }
        'Uninstall' { Invoke-UninstallStage }
    }
} catch {
    Add-InstallerLogLine ('ERROR: ' + $_.Exception.Message)
    Write-Error $_
    exit 1
}
