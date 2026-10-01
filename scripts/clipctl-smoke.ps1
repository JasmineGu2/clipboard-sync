# Smoke test for clipctl on Windows. Run from the repo root after `swift build --product clipctl`:
#   powershell -ExecutionPolicy Bypass -File scripts\clipctl-smoke.ps1
# Uses a throwaway --home and an unreachable relay (commands warn "offline"), and puts your clipboard back at the end.
param(
    [string]$Exe = "",
    [string]$Server = "http://127.0.0.1:9"
)
$ErrorActionPreference = "Continue"
Add-Type -AssemblyName System.Windows.Forms

$repo = Split-Path -Parent $PSScriptRoot
if (-not $Exe) {
    $Exe = Join-Path $repo ".build\out\Products\Debug-windows-x86_64\clipctl.exe"
    if (-not (Test-Path $Exe)) { $Exe = Join-Path $repo ".build\debug\clipctl.exe" }
}
if (-not (Test-Path $Exe)) { Write-Host "clipctl.exe not found; build it first"; exit 1 }

# The Swift runtime DLLs must be on PATH.
$runtime = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes\*\usr\bin" -Directory -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($runtime) { $env:PATH = "$($runtime.FullName);$env:PATH" }
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$home_ = Join-Path $env:TEMP ("clipctl-smoke-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$failures = 0
$savedClipboard = Get-Clipboard -Raw

function Clip { & $Exe --home $home_ @args }
function Step($name) { Write-Host ""; Write-Host "== $name" -ForegroundColor Cyan }
function Check($ok, $what) {
    if ($ok) { Write-Host "PASS  $what" -ForegroundColor Green }
    else { Write-Host "FAIL  $what" -ForegroundColor Red; $script:failures++ }
}
function Items { @((Clip list --limit 100 --json | Out-String | ConvertFrom-Json)) }
function ItemWithText($text) { Items | Where-Object { $_.text -eq $text } | Select-Object -First 1 }

Write-Host "clipctl: $Exe"
Write-Host "home:    $home_"

Step "init"
Clip init --server $Server --name SmokePC
Check ($LASTEXITCODE -eq 0 -and (Test-Path "$home_\key.dpapi") -and (Test-Path "$home_\config.json")) "init made config.json and key.dpapi"
$keyBytes = [IO.File]::ReadAllBytes("$home_\key.dpapi").Length
Check ($keyBytes -gt 32) "key.dpapi is a DPAPI blob ($keyBytes bytes), not the raw 32-byte key"

Step "add"
Clip add hello
Check ($LASTEXITCODE -eq 0) "add hello (offline warning expected)"
# Through cmd: Windows PowerShell 5.1's pipe to native programs prepends a UTF-8 BOM (clipctl strips it anyway).
cmd /c "echo piped text from stdin| `"$Exe`" --home `"$home_`" add -"
Check ($LASTEXITCODE -eq 0) "add - from a pipe"

Step "list"
Clip list
$hello = ItemWithText "hello"
Check ($null -ne $hello) "list --json has 'hello'"
Check ($null -ne (ItemWithText "piped text from stdin")) "stdin text stored without the trailing newline"

Step "search"
$found = Clip search hel
$found
Check (($found | Out-String) -match $hello.shortID) "search hel finds hello"

Step "pin, tag, rename"
Clip pin $hello.shortID
Clip tag $hello.shortID work
Clip rename $hello.shortID "Greeting"
$hello = ItemWithText "hello"
Check ($hello.pinned -eq $true) "pinned"
Check ($hello.tags -contains "work") "tagged #work"
Check ($hello.title -eq "Greeting") "renamed to Greeting"
Clip list
Clip list --json | Select-Object -First 14

Step "status"
Clip status
Check ($LASTEXITCODE -eq 0) "status"

Step "copy"
Clip copy $hello.shortID
$clip = Get-Clipboard -Raw
Check ($clip -eq "hello") "Get-Clipboard reads back 'hello' (got '$clip')"
$formats = [System.Windows.Forms.Clipboard]::GetDataObject().GetFormats()
Check ($formats -contains "ExcludeClipboardContentFromMonitorProcessing") "copy marks the clipboard ExcludeClipboardContentFromMonitorProcessing"

Step "watch"
$out = Join-Path $home_ "watch.out"
$err = Join-Path $home_ "watch.err"
$watch = Start-Process -FilePath $Exe -ArgumentList @("--home", "`"$home_`"", "watch", "--exit-after", "11") `
    -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
Start-Sleep -Seconds 2

Set-Clipboard "watch-test-123"
Start-Sleep -Seconds 2

$concealed = New-Object System.Windows.Forms.DataObject
$concealed.SetText("concealed-secret-456")
$concealed.SetData("ExcludeClipboardContentFromMonitorProcessing", (New-Object IO.MemoryStream (, [byte[]](1, 0, 0, 0))))
[System.Windows.Forms.Clipboard]::SetDataObject($concealed, $true)
Start-Sleep -Seconds 2

$noHistory = New-Object System.Windows.Forms.DataObject
$noHistory.SetText("no-history-789")
$noHistory.SetData("CanIncludeInClipboardHistory", (New-Object IO.MemoryStream (, [byte[]](0, 0, 0, 0))))
[System.Windows.Forms.Clipboard]::SetDataObject($noHistory, $true)
Start-Sleep -Seconds 2

New-Item -ItemType File -Path "$home_\paused" | Out-Null
Set-Clipboard "paused-text-000"
Start-Sleep -Seconds 1

$watch.WaitForExit(20000) | Out-Null
if (-not $watch.HasExited) { $watch.Kill(); Write-Host "watch did not exit; killed" }
Write-Host "--- watch stdout"; Get-Content $out
Write-Host "--- watch stderr (sync retries expected offline)"; Get-Content $err | Select-Object -First 5
Check ((Get-Content $out -Raw) -match "Stopped\.") "watch exited cleanly"
Check ($null -ne (ItemWithText "watch-test-123")) "watch captured 'watch-test-123'"
Check ($null -eq (ItemWithText "concealed-secret-456")) "ExcludeClipboardContentFromMonitorProcessing content NOT captured"
Check ($null -eq (ItemWithText "no-history-789")) "CanIncludeInClipboardHistory=0 content NOT captured"
Check ($null -eq (ItemWithText "paused-text-000")) "nothing captured while <home>\paused exists"
Check (@(Items | Where-Object { $_.text -eq "hello" }).Count -eq 1) "exactly one 'hello' (copy output not re-captured)"

Step "delete"
Clip delete $hello.shortID
Check ($null -eq (ItemWithText "hello")) "hello is gone after delete"
Clip list

if ($savedClipboard) { Set-Clipboard $savedClipboard }
Write-Host ""
if ($failures -eq 0) { Write-Host "ALL PASSED (home: $home_)" -ForegroundColor Green; exit 0 }
Write-Host "$failures FAILED (home: $home_)" -ForegroundColor Red
exit 1
