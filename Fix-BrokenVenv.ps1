[CmdletBinding(DefaultParameterSetName = 'Venv')]
param(
    [Parameter(ParameterSetName = 'Venv', Position = 0)]
    [string]$VenvPath = '.venv',

    [Parameter(ParameterSetName = 'Scan')]
    [string]$ScanRoot,

    [string]$BasePython,

    [switch]$FixBaseLauncher,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Test-PythonExe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $out = & $Path -c "import sys; print('PYOK%d' % sys.version_info[0])" 2>$null
    } catch {
        return $false
    }
    if ($LASTEXITCODE -ne 0) { return $false }
    return (($out -join "`n") -match 'PYOK3')
}

function Copy-WithRetry {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$Attempts = 15,
        [int]$DelayMs = 200
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return
        } catch {
            if ($i -eq $Attempts) { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Get-PyvenvInfo {
    param([string]$VenvPath)
    $cfg = Join-Path $VenvPath 'pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    $info = [pscustomobject]@{
        Home      = $null
        Version   = $null
        VenvPath  = $VenvPath
    }
    foreach ($line in Get-Content -LiteralPath $cfg -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*home\s*=\s*(.+?)\s*$') {
            $info.Home = $Matches[1]
        } elseif ($line -match '^\s*version_info\s*=\s*(.+?)\s*$') {
            $info.Version = $Matches[1]
        }
    }
    return $info
}

function Find-FallbackPython {
    param([string]$Version)
    $names = New-Object System.Collections.Generic.List[string]
    if ($Version) {
        $majmin = (($Version -split '\.')[0..1] -join '.')
        $names.Add("python$majmin.exe")
    }
    $names.Add('python.exe')
    foreach ($name in $names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and (Test-PythonExe $cmd.Source)) { return $cmd.Source }
    }
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
    if ($py) {
        $arg = if ($Version) { "-$Version" } else { '-3' }
        try {
            $out = & $py.Source $arg -c "import sys; print(sys.executable)" 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) {
                $candidate = ($out | Select-Object -Last 1).Trim()
                if (Test-PythonExe $candidate) { return $candidate }
            }
        } catch { }
    }
    return $null
}

function Find-BasePython {
    param($Info, [string]$Explicit)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Explicit) { $candidates.Add($Explicit) }
    if ($Info -and $Info.Home) {
        $candidates.Add((Join-Path $Info.Home 'python.exe'))
        $candidates.Add((Join-Path $Info.Home 'python3.exe'))
    }
    if ($Info -and $Info.Version) {
        $majmin = (($Info.Version -split '\.')[0..1] -join '.')
        $tag = $majmin.Replace('.', '')
        $candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\Python\Python$tag\python.exe"))
        $candidates.Add((Join-Path $env:ProgramFiles "Python$tag\python.exe"))
    }
    foreach ($candidate in $candidates) {
        if (Test-PythonExe $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    $version = if ($Info) { $Info.Version } else { $null }
    return (Find-FallbackPython -Version $version)
}

function Repair-Venv {
    param([string]$VenvPath, [string]$BasePy, [switch]$Force)
    $resolved = (Resolve-Path -LiteralPath $VenvPath).Path
    $scripts = Join-Path $resolved 'Scripts'
    $venvPy = Join-Path $scripts 'python.exe'
    if (-not (Test-Path -LiteralPath $scripts -PathType Container)) {
        Write-Warning "No Scripts folder in $resolved"
        return $false
    }
    if ((-not $Force) -and (Test-PythonExe $venvPy)) {
        Write-Host "[ok]    $resolved"
        return $true
    }
    $baseDir = Split-Path -Parent $BasePy
    $pairs = [ordered]@{
        'python.exe'  = (Join-Path $baseDir 'python.exe')
        'pythonw.exe' = (Join-Path $baseDir 'pythonw.exe')
    }
    foreach ($name in $pairs.Keys) {
        $source = $pairs[$name]
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            if ($name -eq 'pythonw.exe') {
                Write-Warning "Base pythonw.exe not found at $source; skipping"
                continue
            }
            Write-Error "Base python.exe not found at $source"
            return $false
        }
        Copy-WithRetry -Source $source -Destination (Join-Path $scripts $name)
    }
    if (Test-PythonExe $venvPy) {
        Write-Host "[fixed] $resolved"
        return $true
    }
    Write-Error "Could not repair $resolved"
    return $false
}

function Repair-BaseLauncher {
    param([string]$BasePy, [switch]$Force)
    $baseDir = Split-Path -Parent $BasePy
    $nt = Join-Path $baseDir 'Lib\venv\scripts\nt'
    if (-not (Test-Path -LiteralPath $nt -PathType Container)) { return }
    $pairs = [ordered]@{
        'venvlauncher.exe'  = (Join-Path $baseDir 'python.exe')
        'venvwlauncher.exe' = (Join-Path $baseDir 'pythonw.exe')
    }
    foreach ($name in $pairs.Keys) {
        $launcher = Join-Path $nt $name
        $real = $pairs[$name]
        if (-not (Test-Path -LiteralPath $real -PathType Leaf)) { continue }
        if (Test-Path -LiteralPath $launcher) {
            if (-not $Force) {
                $launcherHash = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
                $realHash = (Get-FileHash -LiteralPath $real -Algorithm SHA256).Hash
                if ($launcherHash -eq $realHash) { continue }
            }
            Copy-WithRetry -Source $launcher -Destination "$launcher.bak"
        }
        Copy-WithRetry -Source $real -Destination $launcher
        Write-Host "[base] repaired $launcher"
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Scan') {
    if ([string]::IsNullOrWhiteSpace($ScanRoot)) { $ScanRoot = '.' }
    if (-not (Test-Path -LiteralPath $ScanRoot)) { throw "ScanRoot not found: $ScanRoot" }
    $root = (Resolve-Path -LiteralPath $ScanRoot).Path
    $venvDirs = @(
        Get-ChildItem -LiteralPath $root -Filter 'pyvenv.cfg' -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Directory.FullName } |
            Select-Object -Unique
    )
    if ($venvDirs.Count -eq 0) {
        Write-Host 'No virtual environments found.'
        return
    }
} else {
    if (-not (Test-Path -LiteralPath $VenvPath)) { throw "Virtual environment not found: $VenvPath" }
    $venvDirs = @((Resolve-Path -LiteralPath $VenvPath).Path)
}

$failed = 0
$basesUsed = @{}
foreach ($venv in $venvDirs) {
    $info = Get-PyvenvInfo -VenvPath $venv
    $base = Find-BasePython -Info $info -Explicit $BasePython
    if (-not $base) {
        Write-Warning "No working base Python found for $venv"
        $failed++
        continue
    }
    if (-not (Repair-Venv -VenvPath $venv -BasePy $base -Force:$Force)) {
        $failed++
    }
    $basesUsed[$base] = $true
}

if ($FixBaseLauncher) {
    foreach ($base in $basesUsed.Keys) {
        Repair-BaseLauncher -BasePy $base -Force:$Force
    }
}

if ($failed -gt 0) { exit 1 }
