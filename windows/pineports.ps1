param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'test')]
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

function Resolve-Python3 {
    $candidates = @(Get-Command python.exe -All -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ File = $_.Source; Prefix = @() } })
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        $candidates += [pscustomobject]@{ File = $launcher.Source; Prefix = @('-3') }
    }

    $fallback = $null
    foreach ($candidate in $candidates) {
        $versionArgs = @($candidate.Prefix) + @(
            '-c', 'import sys; raise SystemExit(sys.version_info < (3, 8))')
        & $candidate.File @versionArgs 2>$null
        if ($LASTEXITCODE -eq 0) {
            if (-not $fallback) { $fallback = $candidate }
            # Avoid an ImportError traceback: Windows PowerShell 5.1 treats
            # native stderr as terminating when ErrorActionPreference is Stop.
            $psutilArgs = @($candidate.Prefix) + @(
                '-c', "import importlib.util; raise SystemExit(importlib.util.find_spec('psutil') is None)")
            & $candidate.File @psutilArgs 2>$null
            if ($LASTEXITCODE -eq 0) { return $candidate }
        }
    }

    if ($fallback) {
        $installArgs = @($fallback.Prefix) + @('-m', 'pip', 'install', 'psutil')
        throw ('psutil is not installed for any available Python 3.8+. Run: "' +
               $fallback.File + '" ' + ($installArgs -join ' '))
    }
    throw 'Python 3.8 or newer was not found on PATH.'
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

function Start-PinePort {
    $existing = Get-PinePortProcess
    if ($existing) {
        [IO.Directory]::CreateDirectory($configDir) | Out-Null
        Set-Content -LiteralPath $pidFile -Value $existing.ProcessId
        Write-Host "PinePort is already running (pid $($existing.ProcessId))."
        Start-Process "http://localhost:$webPort/"
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
    Write-Host "Dashboard: http://localhost:$webPort/"
    Start-Process "http://localhost:$webPort/"
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

function Test-PinePort {
    $python = Resolve-Python3
    Push-Location $repoRoot
    try {
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
