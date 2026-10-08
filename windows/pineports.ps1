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
    $candidate = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($candidate) {
        & $candidate.Source -c 'import sys; raise SystemExit(sys.version_info.major != 3)' 2>$null
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{ File = $candidate.Source; Prefix = @() }
        }
    }

    $candidate = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($candidate) {
        & $candidate.Source -3 -c 'import sys; raise SystemExit(sys.version_info.major != 3)' 2>$null
        if ($LASTEXITCODE -eq 0) {
            return [pscustomobject]@{ File = $candidate.Source; Prefix = @('-3') }
        }
    }

    throw 'Python 3 was not found on PATH.'
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
