# End-to-end test (T09): the real relay in WSL Ubuntu, two clipctl "devices" on Windows.
#   powershell -ExecutionPolicy Bypass -File scripts\e2e.ps1
# Needs: `swift build --product clipctl` on Windows, and the relay built in WSL at /root/clip/Server
# (see Server/README.md). Uses a fresh relay database and throwaway --home folders; exits 1 on any failure.
param(
    [string]$Exe = "",
    [int]$Port = 8787,
    [string]$Relay = "/root/clip/Server/.build/release/ClipRelay"
)
$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $repo ".build\out\Products\Debug-windows-x86_64\clipctl.exe" }
if (-not (Test-Path $Exe)) { Write-Host "clipctl.exe not found; run swift build first"; exit 1 }
$runtime = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes\*\usr\bin" -Directory -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($runtime) { $env:PATH = "$($runtime.FullName);$env:PATH" }
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$server = "http://127.0.0.1:$Port"
$run = [guid]::NewGuid().ToString("N").Substring(0, 8)
$homeA = Join-Path $env:TEMP "clip-e2e-$run-A"
$homeB = Join-Path $env:TEMP "clip-e2e-$run-B"
$failures = 0
$latencies = @()

function A { & $Exe --home $homeA @args 2>&1 }
function B { & $Exe --home $homeB @args 2>&1 }
function Check($ok, $what) {
    if ($ok) { Write-Host "PASS  $what" } else { Write-Host "FAIL  $what" -ForegroundColor Red; $script:failures++ }
}
# PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE object; unroll it into separate items.
function ItemsOf($who) { (& $who list --json --limit 200 | Out-String) | ConvertFrom-Json | ForEach-Object { $_ } }
# Polls `who` until `test` is true for its items; returns elapsed ms, or -1 on timeout.
function WaitFor($who, [scriptblock]$test, [int]$timeoutMs = 10000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $items = @(ItemsOf $who)
        if (& $test $items) { return $sw.ElapsedMilliseconds }
        Start-Sleep -Milliseconds 100
    }
    return -1
}

Write-Host "== starting relay in WSL on $server"
$relayProc = Start-Process wsl -ArgumentList @("-d", "Ubuntu-24.04", "-u", "root", "--", $Relay, "--host", "127.0.0.1", "--port", "$Port", "--db", "/tmp/clip-e2e-$run.db") -PassThru -WindowStyle Hidden
$up = $false
for ($i = 0; $i -lt 50; $i++) {
    try { if ((Invoke-WebRequest "$server/healthz" -UseBasicParsing -TimeoutSec 1).Content -eq "ok") { $up = $true; break } } catch {}
    Start-Sleep -Milliseconds 200
}
Check $up "relay answers /healthz"
if (-not $up) { exit 1 }

$watchers = @()
try {
    Write-Host "== pairing"
    A init --server $server --name "E2E-A" | Out-Null
    $pair = A pair start | Out-String
    $code = [regex]::Match($pair, "Pairing code: (\S+)").Groups[1].Value
    Check ($code.Length -gt 0) "A printed a pairing code"
    B pair join --server $server $code --name "E2E-B" | Out-Null
    Check (Test-Path (Join-Path $homeB "key.dpapi")) "B joined and stored the vault key with DPAPI"

    Write-Host "== live sync (both devices running watch)"
    foreach ($h in @($homeA, $homeB)) {
        $watchers += Start-Process $Exe -ArgumentList @("--home", "`"$h`"", "watch", "--exit-after", "60") -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $h "watch.log") -RedirectStandardError (Join-Path $h "watch.err")
    }
    Start-Sleep -Seconds 2

    for ($n = 1; $n -le 5; $n++) {
        $text = "e2e-$run-from-A-$n"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        A add $text | Out-Null
        $ms = WaitFor ${function:B} { param($items) $items | Where-Object { $_.text -eq $text } }
        if ($ms -ge 0) { $latencies += $sw.ElapsedMilliseconds }
        Check ($ms -ge 0) "A -> B: '$text' arrived ($($sw.ElapsedMilliseconds) ms)"
    }

    $text = "e2e-$run-from-B"
    B add $text | Out-Null
    $ms = WaitFor ${function:A} { param($items) $items | Where-Object { $_.text -eq $text } }
    Check ($ms -ge 0) "B -> A: '$text' arrived"

    Write-Host "== edits sync both ways"
    $target = @(ItemsOf ${function:A}) | Where-Object { $_.text -eq "e2e-$run-from-A-1" } | Select-Object -First 1
    Check ($null -ne $target) "found the item to edit"
    A pin $target.shortID | Out-Null
    A tag $target.shortID work | Out-Null
    B rename $target.shortID "Renamed on B" | Out-Null
    $ms = WaitFor ${function:B} { param($items) $items | Where-Object { $_.id -eq $target.id -and $_.pinned -and ($_.tags -contains "work") } }
    Check ($ms -ge 0) "B sees A's pin and tag"
    $ms = WaitFor ${function:A} { param($items) $items | Where-Object { $_.id -eq $target.id -and $_.title -eq "Renamed on B" } }
    Check ($ms -ge 0) "A sees B's rename"

    B delete $target.shortID | Out-Null
    $ms = WaitFor ${function:A} { param($items) -not ($items | Where-Object { $_.id -eq $target.id }) }
    Check ($ms -ge 0) "B's delete reaches A"

    Write-Host "== convergence"
    A sync | Out-Null; B sync | Out-Null
    $a = (@(ItemsOf ${function:A}) | ForEach-Object { "$($_.id)|$($_.text)|$($_.title)|$($_.pinned)|$($_.tags -join ',')" } | Sort-Object) -join "`n"
    $b = (@(ItemsOf ${function:B}) | ForEach-Object { "$($_.id)|$($_.text)|$($_.title)|$($_.pinned)|$($_.tags -join ',')" } | Sort-Object) -join "`n"
    Check ($a -eq $b -and $a.Length -gt 0) "A and B hold identical histories ($(@($a -split "`n").Count) items)"
}
finally {
    foreach ($w in $watchers) { if (-not $w.HasExited) { Stop-Process -Id $w.Id -Force -ErrorAction SilentlyContinue } }
    wsl -d Ubuntu-24.04 -u root -- pkill -f "clip-e2e-$run" 2>$null | Out-Null
    if ($relayProc -and -not $relayProc.HasExited) { Stop-Process -Id $relayProc.Id -Force -ErrorAction SilentlyContinue }
}

if ($latencies.Count -gt 0) {
    $sorted = $latencies | Sort-Object
    $p50 = $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
    Write-Host ("A -> B latency over {0} items: p50 {1} ms, max {2} ms (includes clipctl process start for each poll)" -f $sorted.Count, $p50, $sorted[-1])
}
if ($failures -eq 0) { Write-Host "ALL PASSED"; exit 0 } else { Write-Host "$failures FAILED" -ForegroundColor Red; exit 1 }
