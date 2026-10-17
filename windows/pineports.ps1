param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'open', 'settings', 'test',
                 'startup-status', 'startup-enable', 'startup-disable')]
    [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pineports = Join-Path $repoRoot 'pineports'
$configDir = Join-Path $env:APPDATA 'pineports'
$pinFile = Join-Path $configDir 'pineports-pin'
$pidFile = Join-Path $configDir 'pineports.pid'
$stdoutLog = Join-Path $configDir 'pineports.stdout.log'
$stderrLog = Join-Path $configDir 'pineports.stderr.log'
$webPort = 6310
$dashboardUrl = "https://localhost:$webPort/"
$startupDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
$startupShortcut = if ($startupDirectory) {
    Join-Path $startupDirectory 'PinePort.lnk'
} else {
    $null
}

function Resolve-Python3 {
    # Probes run outside PowerShell's stderr pipeline: with
    # $ErrorActionPreference = 'Stop', PowerShell 5.1 turns a native command's
    # first stderr line (e.g. a Python ImportError traceback or the Store
    # stub's "Python was not found") into a terminating NativeCommandError,
    # even when redirected to $null. System.Diagnostics.Process keeps that
    # output contained so exit codes are all we look at.
    $versionProbe = 'import sys; raise SystemExit(sys.version_info < (3, 11))'
    $dependencyProbe = (
        'import cryptography, psutil; ' +
        'from cryptography.hazmat.primitives.kdf.argon2 import Argon2id; ' +
        "Argon2id(salt=b'0'*16,length=16,iterations=1,lanes=1,memory_cost=8).derive(b'x'); " +
        "raise SystemExit(tuple(map(int, cryptography.__version__.split(chr(46))[:3])) < (50, 0, 2))")

    function Invoke-PythonProbe {
        param($File, [string[]]$Prefix, [string]$Code)
        $arguments = ((@($Prefix) + @('-c', $Code)) | ForEach-Object {
            if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
        }) -join ' '
        $psi = [System.Diagnostics.ProcessStartInfo]@{
            FileName = $File
            Arguments = $arguments
            UseShellExecute = $false
            CreateNoWindow = $true
            RedirectStandardOutput = $true
            RedirectStandardError = $true
        }
        try {
            $process = [System.Diagnostics.Process]::Start($psi)
        } catch {
            return $false
        }
        try {
            if (-not $process.WaitForExit(15000)) {
                try { $process.Kill() } catch { }
                return $false
            }
            return ($process.ExitCode -eq 0)
        } finally {
            $process.Dispose()
        }
    }

    $candidates = @(Get-Command python.exe -All -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ File = $_.Source; Prefix = @() } })
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        foreach ($selector in @('-3', '-3.14', '-3.13', '-3.12', '-3.11')) {
            $candidates += [pscustomobject]@{
                File = $launcher.Source
                Prefix = @($selector)
            }
        }
    }

    $fallback = $null
    foreach ($candidate in $candidates) {
        if (-not (Invoke-PythonProbe $candidate.File $candidate.Prefix $versionProbe)) {
            continue
        }
        if (-not $fallback) { $fallback = $candidate }
        if (Invoke-PythonProbe $candidate.File $candidate.Prefix $dependencyProbe) {
            return $candidate
        }
    }

    if ($fallback) {
        $installArgs = @($fallback.Prefix) + @(
            '-m', 'pip', 'install', '--upgrade', 'psutil', '"cryptography>=50.0.2"')
        throw ('PinePort dependencies are not installed for any available Python 3.11+. Run: "' +
               $fallback.File + '" ' + ($installArgs -join ' '))
    }
    throw 'Python 3.11 or newer was not found on PATH.'
}

function Test-PinePortProcess {
    param($Process)
    if (-not $Process -or -not $Process.CommandLine) { return $false }
    return ($Process.CommandLine -match '(?i)(?:^|[\\/\s"])pineports(?:["\s]|$)' -and
            $Process.CommandLine -match '(?:^|\s)--web(?:\s|$)')
}

function Get-CimProcessById {
    param([int]$ProcessId)
    return Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
}

function Get-PinePortProcess {
    if (Test-Path -LiteralPath $pidFile -PathType Leaf) {
        $saved = 0
        if ([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$saved)) {
            $process = Get-CimProcessById $saved
            if (Test-PinePortProcess $process) { return $process }
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }

    $listeners = Get-NetTCPConnection -State Listen -LocalPort $webPort -ErrorAction SilentlyContinue
    foreach ($listener in $listeners) {
        $process = Get-CimProcessById $listener.OwningProcess
        if (Test-PinePortProcess $process) { return $process }
    }
    return $null
}

function Invoke-Python {
    param($Python, [string[]]$Arguments)
    $allArguments = @($Python.Prefix) + $Arguments
    & $Python.File @allArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Python exited with code $LASTEXITCODE."
    }
}

function ConvertTo-ArgumentString {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    }) -join ' ')
}

function Get-PinePortStartupArguments {
    $scriptPath = Join-Path $PSScriptRoot 'pineports.ps1'
    return '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
        $scriptPath + '" start'
}

function Test-PinePortStartup {
    if ([string]::IsNullOrWhiteSpace($script:startupShortcut)) { return $false }
    return Test-Path -LiteralPath $script:startupShortcut -PathType Leaf
}

function Enable-PinePortStartup {
    if ([string]::IsNullOrWhiteSpace($script:startupShortcut)) {
        throw 'The Windows Startup folder could not be found.'
    }

    [IO.Directory]::CreateDirectory((Split-Path -Parent $script:startupShortcut)) |
        Out-Null
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($script:startupShortcut)
    $shortcut.TargetPath = $powershell
    $shortcut.Arguments = Get-PinePortStartupArguments
    $shortcut.WorkingDirectory = $repoRoot
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Start PinePort in the background at Windows sign-in'
    $shortcut.Save()
}

function Disable-PinePortStartup {
    if ([string]::IsNullOrWhiteSpace($script:startupShortcut)) {
        throw 'The Windows Startup folder could not be found.'
    }
    Remove-Item -LiteralPath $script:startupShortcut -Force -ErrorAction SilentlyContinue
}

function Write-PinePortStartupStatus {
    [pscustomobject]@{
        enabled = [bool](Test-PinePortStartup)
    } | ConvertTo-Json -Compress
}

function Set-PinePortPin {
    $python = Resolve-Python3
    Invoke-Python $python @($pineports, '--set-pin')
    Write-Host 'Dashboard PIN changed. Existing browser sessions must sign in again.'
}

function Start-PinePort {
    $existing = Get-PinePortProcess
    if ($existing) {
        [IO.Directory]::CreateDirectory($configDir) | Out-Null
        Set-Content -LiteralPath $pidFile -Value $existing.ProcessId
        Write-Host "PinePort is already running (pid $($existing.ProcessId))."
        return
    }

    $python = Resolve-Python3
    [IO.Directory]::CreateDirectory($configDir) | Out-Null
    if (-not (Test-Path -LiteralPath $pinFile -PathType Leaf)) {
        Write-Host 'No dashboard PIN exists yet.'
        Invoke-Python $python @($pineports, '--set-pin')
    }

    $arguments = @($python.Prefix) + @($pineports, '--web')
    $process = Start-Process -FilePath $python.File `
        -ArgumentList (ConvertTo-ArgumentString $arguments) `
        -WorkingDirectory $repoRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    $listenerProcess = $null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        Start-Sleep -Milliseconds 100
        $listenerProcess = Get-PinePortProcess
        if ($listenerProcess) { break }
        if ($process.HasExited) {
            $detail = if (Test-Path -LiteralPath $stderrLog) {
                (Get-Content -LiteralPath $stderrLog -Raw).Trim()
            } else { '' }
            throw "PinePort exited during startup. $detail"
        }
    }
    if (-not $listenerProcess) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "PinePort did not begin listening on port $webPort."
    }

    Set-Content -LiteralPath $pidFile -Value $listenerProcess.ProcessId
    Write-Host "PinePort started (pid $($listenerProcess.ProcessId))."
    Write-Host "Dashboard: $dashboardUrl"
}

function Open-PinePort {
    if (-not (Get-PinePortProcess)) {
        Write-Host 'PinePort is not running; starting it now.'
        Start-PinePort
    }
    else {
        Write-Host 'PinePort is already running.'
    }
    Write-Host "Opening $dashboardUrl"
    Start-Process $dashboardUrl
}

function Stop-PinePort {
    $process = Get-PinePortProcess
    if (-not $process) {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        Write-Host 'PinePort is not running.'
        return
    }

    $processId = [int]$process.ProcessId
    Stop-Process -Id $processId -Force
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 100
    }
    if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
        throw "PinePort process $processId did not stop."
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    Write-Host "PinePort stopped (pid $processId)."
}

function Show-PinePortSettings {
    while ($true) {
        $startupState = if (Test-PinePortStartup) { 'enabled' } else { 'disabled' }
        $startupAction = if (Test-PinePortStartup) { 'Disable' } else { 'Enable' }

        Write-Host ''
        Write-Host 'PinePort settings'
        Write-Host '-----------------'
        Write-Host "Launch at Windows sign-in: $startupState"
        Write-Host ''
        Write-Host "1. $startupAction launch at Windows sign-in"
        Write-Host '2. Change dashboard PIN'
        Write-Host '3. Exit'
        Write-Host ''

        $choice = [string](Read-Host 'Choose an option')
        switch ($choice.Trim().ToLowerInvariant()) {
            '1' {
                if (Test-PinePortStartup) {
                    Disable-PinePortStartup
                    Write-Host 'PinePort will no longer start at Windows sign-in.'
                }
                else {
                    if (-not (Test-Path -LiteralPath $pinFile -PathType Leaf)) {
                        Write-Host 'Set a dashboard PIN before enabling automatic startup.'
                        Set-PinePortPin
                    }
                    Enable-PinePortStartup
                    Write-Host 'PinePort will now start in the background at Windows sign-in.'
                }
            }
            '2' { Set-PinePortPin }
            '3' { return }
            'q' { return }
            'quit' { return }
            default { Write-Warning 'Choose 1, 2, or 3.' }
        }
    }
}

function Test-WindowsLaunchers {
    $expectedLaunchers = @{
        'start-pineports.cmd' = 'start'
        'stop-pineports.cmd' = 'stop'
        'restart-pineports.cmd' = 'restart'
        'open-pineports.cmd' = 'open'
        'settings-pineports.cmd' = 'settings'
        'test-pineports.cmd' = 'test'
    }
    foreach ($entry in $expectedLaunchers.GetEnumerator()) {
        $path = Join-Path $repoRoot $entry.Key
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing Windows launcher: $($entry.Key)"
        }
        $content = Get-Content -LiteralPath $path -Raw
        $expected = 'pineports.ps1" ' + $entry.Value
        if ($content -notlike "*$expected*") {
            throw "$($entry.Key) does not invoke the '$($entry.Value)' action."
        }
    }

    $originalShortcut = $script:startupShortcut
    $testDirectory = Join-Path ([IO.Path]::GetTempPath()) (
        'pineports-launcher-test-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($testDirectory) | Out-Null
        $script:startupShortcut = Join-Path $testDirectory 'PinePort.lnk'
        Enable-PinePortStartup
        if (-not (Test-PinePortStartup)) {
            throw 'Enabling startup did not create the shortcut.'
        }

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($script:startupShortcut)
        $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
        if ($shortcut.TargetPath -ine $powershell) {
            throw 'The startup shortcut does not target Windows PowerShell.'
        }
        if ($shortcut.Arguments -cne (Get-PinePortStartupArguments)) {
            throw 'The startup shortcut has unexpected arguments.'
        }
        if ($shortcut.WorkingDirectory -ine $repoRoot) {
            throw 'The startup shortcut has the wrong working directory.'
        }

        Disable-PinePortStartup
        if (Test-PinePortStartup) {
            throw 'Disabling startup did not remove the shortcut.'
        }
    }
    finally {
        $script:startupShortcut = $originalShortcut
        Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-PinePort {
    $python = Resolve-Python3
    Push-Location $repoRoot
    try {
        Write-Host 'Running Windows launcher tests...'
        Test-WindowsLaunchers
        Write-Host 'Running cross-platform tests...'
        Invoke-Python $python @((Join-Path $repoRoot 'test_crossplatform.py'))
        Write-Host 'Running real-Windows tests...'
        Invoke-Python $python @((Join-Path $repoRoot 'test_windows.py'))
        Write-Host 'All PinePort Windows tests passed.'
    }
    finally {
        Pop-Location
    }
}

try {
    switch ($Action) {
        'start' { Start-PinePort }
        'stop' { Stop-PinePort }
        'open' { Open-PinePort }
        'settings' { Show-PinePortSettings }
        'startup-status' { Write-PinePortStartupStatus }
        'startup-enable' {
            Enable-PinePortStartup
            Write-PinePortStartupStatus
        }
        'startup-disable' {
            Disable-PinePortStartup
            Write-PinePortStartupStatus
        }
        'restart' {
            Stop-PinePort
            Start-PinePort
        }
        'test' { Test-PinePort }
    }
}
catch {
    Write-Error $_
    exit 1
}
