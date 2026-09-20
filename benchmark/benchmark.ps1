# Scoop-Shim startup benchmark.
#
# Candidates run without the system shell (hyperfine --shell=none escapes
# backslashes, so paths use forward slashes) and are interleaved in randomized
# rounds. Values are pooled medians with the inter-quartile range; CPU time
# (user+system) is reported next to wall clock because wall clock is unreliable on
# a busy machine.
#
# Usage:
#   pwsh -File benchmark/benchmark.ps1
#   pwsh -File benchmark/benchmark.ps1 -Rounds 20 -Runs 25 -Warmup 5
param(
    [int]$Rounds = 10,
    [int]$Runs = 15,
    [int]$Warmup = 5,
    [string]$Arch = '',
    [switch]$UseShell
)

$ErrorActionPreference = "Stop"

$hf = (Get-Command hyperfine -ErrorAction SilentlyContinue).Source
if (-not $hf) {
    Write-Host "[FAIL] hyperfine not found. Install with:" -ForegroundColor Red
    Write-Host "  scoop install hyperfine" -ForegroundColor Yellow
    exit 1
}

$benchDir = $PSScriptRoot
$sd = Join-Path $benchDir "shims"
$reporoot = (Get-Item $benchDir).Parent.FullName

if (-not $Arch) {
    $Arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture) {
        "X64" { "x64" }
        "X86" { "x86" }
        "Arm64" { "arm64" }
        default { "x64" }
    }
}
Write-Host "[Arch] $Arch" -ForegroundColor Cyan

# The direct baseline is whatever the template points at.
$template = Join-Path $sd "template.shim"
switch -Regex (Get-Content $template) {
    '^path\s*=\s*(.+)' { $refExe = $Matches[1].Trim(); break }
}
if (-not $refExe -or -not (Test-Path $refExe)) {
    Write-Host "[FAIL] baseline target not found from template: $refExe" -ForegroundColor Red
    exit 1
}

# name -> source exe; shims are staged once so file state stays constant.
$impls = [ordered]@{
    "direct" = $refExe
    "Rust"   = "$reporoot\rust\bin\$Arch\shim.exe"
    "C++"    = "$reporoot\cpp\bin\$Arch\shim.exe"
    "C#"     = "$reporoot\cs\bin\$Arch\shim.exe"
    "Zig"    = "$reporoot\zig\bin\$Arch\shim.exe"
}

Write-Host "[Setup]" -ForegroundColor Cyan
$paths = [ordered]@{}
foreach ($name in $impls.Keys) {
    $src = $impls[$name]
    if ($name -eq "direct") {
        $paths[$name] = $refExe
        Write-Host "  direct  -> $refExe" -ForegroundColor Gray
        continue
    }
    if (-not (Test-Path $src)) {
        Write-Warning "$name source not found: $src"
        continue
    }
    $dest = Join-Path $sd "shim-$name.exe"
    Copy-Item $src $dest -Force
    Copy-Item $template ($dest -replace '\.exe$', '.shim') -Force
    $paths[$name] = $dest
    Write-Host ("  {0,-7} {1,6} KB" -f $name, [Math]::Round((Get-Item $dest).Length / 1KB)) -ForegroundColor Gray
}

# --shell=none: shell-words treats backslashes as escapes, and an unquoted space
# would split the argument - so fall back to the shell if a path has whitespace.
$noShell = -not $UseShell
if ($noShell -and ($paths.Values | Where-Object { $_ -match '\s' })) {
    Write-Warning "A command path contains whitespace; falling back to shell mode."
    $noShell = $false
}
$commandPaths = [ordered]@{}
foreach ($name in $paths.Keys) {
    $commandPaths[$name] = if ($noShell) { $paths[$name] -replace '\\', '/' } else { $paths[$name] }
}
Write-Host ("[Mode] {0}" -f ($(if ($noShell) { "--shell=none (direct exec)" } else { "system shell" }))) -ForegroundColor Cyan

# Canary: a shim that fails to launch exits in ~2 ms, which would top the table.
# Drop nonzero exits before timing.
Write-Host "[Canary]" -ForegroundColor Cyan
foreach ($name in @($paths.Keys)) {
    if ($name -eq "direct") { continue }
    $out = & $commandPaths[$name] *> $null
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Warning "$name failed canary run (exit $code) - excluded from timing"
        $paths.Remove($name)
    }
}

# name -> pooled wall samples (ms) and per-round CPU samples (ms)
$wall = @{}
$cpu = @{}
foreach ($name in $paths.Keys) {
    $wall[$name] = New-Object System.Collections.ArrayList
    $cpu[$name] = New-Object System.Collections.ArrayList
}

$names = @($paths.Keys)
Write-Host "[Bench] $Rounds rounds x $Runs runs, warmup $Warmup once (order randomized per round)" -ForegroundColor Cyan
for ($round = 1; $round -le $Rounds; $round++) {
    # Warm up once; the cold-start cost does not recur.
    $w = if ($round -eq 1) { $Warmup } else { 0 }
    foreach ($name in ($names | Sort-Object { Get-Random })) {
        $tmp = Join-Path $env:TEMP "shim-bench-$PID.json"
        $hfArgs = @("-w", "$w", "-r", "$Runs", "--export-json", $tmp, "--ignore-failure")
        if ($noShell) { $hfArgs += "--shell=none" }
        $hfArgs += $commandPaths[$name]

        & $hf @hfArgs 2>&1 | Out-Null
        $r = (Get-Content $tmp -Raw | ConvertFrom-Json).results[0]
        if (@($r.times).Count -eq 0) {
            Write-Warning "$name produced no samples - command failed to run: $($commandPaths[$name])"
        }
        foreach ($t in $r.times) { [void]$wall[$name].Add([double]$t * 1000) }
        [void]$cpu[$name].Add(($r.user + $r.system) * 1000)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  round $round/$Rounds" -ForegroundColor DarkGray
}

function Get-Stat {
    param([double[]]$Values)
    $s = @($Values | Sort-Object)
    if ($s.Count -eq 0) { return [pscustomobject]@{ Median = [double]::NaN; Iqr = [double]::NaN } }
    $last = $s.Count - 1
    # [int] rounds .5 to even and can overrun a small array; floor and clamp instead.
    $mIdx = [Math]::Min($last, [int][Math]::Floor($s.Count * 0.5))
    $loIdx = [Math]::Min($last, [int][Math]::Floor($s.Count * 0.25))
    $hiIdx = [Math]::Min($last, [int][Math]::Floor($s.Count * 0.75))
    return [pscustomobject]@{
        Median = [Math]::Round($s[$mIdx], 1)
        Iqr    = [Math]::Round($s[$hiIdx] - $s[$loIdx], 1)
    }
}

$stats = @{}
foreach ($name in $names) {
    $w = Get-Stat @($wall[$name])
    $c = Get-Stat @($cpu[$name])
    $stats[$name] = [pscustomobject]@{ Wall = $w.Median; WallIqr = $w.Iqr; Cpu = $c.Median; CpuIqr = $c.Iqr }
}

$refCpu = $stats["direct"].Cpu

Write-Host "`n=== Startup latency ($Rounds rounds x $Runs runs) ===`n" -ForegroundColor Cyan
Write-Host ("{0,-8} {1,10} {2,10} {3,10} {4,10} {5,14}" -f "Shim", "Wall[ms]", "WallIQR", "CPU[ms]", "CPUIQR", "CPU overhead")
foreach ($name in $names) {
    $s = $stats[$name]
    $overhead = if ($name -eq "direct") { "-" } else { "{0:+0.0;-0.0;0}" -f ($s.Cpu - $refCpu) }
    Write-Host ("{0,-8} {1,10} {2,10} {3,10} {4,10} {5,14}" -f $name, $s.Wall, $s.WallIqr, $s.Cpu, $s.CpuIqr, $overhead)
}

# Flag rankings the noise cannot resolve.
$ranked = @($names | Where-Object { $_ -ne "direct" } | Sort-Object { $stats[$_].Cpu })
$unresolved = $false
for ($i = 0; $i -lt $ranked.Count - 1; $i++) {
    $a = $stats[$ranked[$i]]
    $b = $stats[$ranked[$i + 1]]
    if ($b.Cpu - $a.Cpu -lt (($a.CpuIqr + $b.CpuIqr) / 2)) {
        Write-Host "Note: $($ranked[$i]) and $($ranked[$i + 1]) overlap within their IQR - not resolvable." -ForegroundColor Yellow
        $unresolved = $true
    }
}
if (-not $unresolved) { Write-Host "Note: all shims are separated by more than their IQR." -ForegroundColor DarkGray }

# --- export -------------------------------------------------------------------

$resultsJson = Join-Path $benchDir "results.json"
[ordered]@{
    arch     = $Arch
    mode     = if ($noShell) { "shell=none" } else { "shell" }
    rounds   = $Rounds
    runs     = $Runs
    warmup   = $Warmup
    baseline = "direct"
    results  = @(foreach ($name in $names) {
            [ordered]@{
                command     = $name
                wallMedian  = $stats[$name].Wall
                wallIqr     = $stats[$name].WallIqr
                cpuMedian   = $stats[$name].Cpu
                cpuIqr      = $stats[$name].CpuIqr
                cpuOverhead = if ($name -eq "direct") { $null } else { [Math]::Round($stats[$name].Cpu - $refCpu, 1) }
            }
        })
} | ConvertTo-Json -Depth 6 | Set-Content $resultsJson -Encoding utf8

$md = @()
$md += "| Implementation | Wall median [ms] | Wall IQR | CPU median [ms] | CPU IQR | CPU overhead [ms] |"
$md += "| -------------- | ---------------: | -------: | --------------: | ------: | ----------------: |"
foreach ($name in $names) {
    $s = $stats[$name]
    $overhead = if ($name -eq "direct") { "-" } else { "{0:+0.0;-0.0;0}" -f ($s.Cpu - $refCpu) }
    $md += "| $name | $($s.Wall) | $($s.WallIqr) | $($s.Cpu) | $($s.CpuIqr) | $overhead |"
}
$resultsMd = Join-Path $benchDir "results.md"
$md | Set-Content $resultsMd -Encoding utf8

Write-Host "`nResults written to:" -ForegroundColor Cyan
Write-Host "  $resultsMd"
Write-Host "  $resultsJson"
