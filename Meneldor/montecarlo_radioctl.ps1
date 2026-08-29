#requires -Version 5.1
<#
  montecarlo_radioctl.ps1 — randomized tests for radioctl.ps1 (Windows side).

  NOTE: this harness could not be executed in the authoring sandbox (no pwsh).
  It is the Windows counterpart to montecarlo_radioctl.sh and mirrors its
  scenarios. It dot-sources radioctl.ps1 (which now guards its REPL against
  dot-sourcing) and Monte-Carlos the PURE decision logic — Resolve-Key
  (config precedence), Validate-Freq (per-backend range), Caps-For, and
  Get-Profiles (fleet enumeration). The I/O paths (mock loopback, dispatch)
  are covered by the bash harness that passed and by exact structural parity
  (identical command surface; 29/29 backend functions).

  Run:  pwsh -File .\montecarlo_radioctl.ps1 [-Runs 2000]
#>
param([int]$Runs = 2000, [int]$Seed = 12345)

. "$PSScriptRoot\radioctl.ps1"          # dot-source: loads functions, no REPL

$rng  = [System.Random]::new($Seed)
function RR([int]$lo,[int]$hi){ $rng.Next($lo, $hi + 1) }

$pass = 0; $fail = 0; $details = @()
function Assert($scn,[bool]$ok,$msg){
  if ($ok) { $script:pass++ } else { $script:fail++; $script:details += "[$scn] $msg" }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("mc-radioctl-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

for ($i = 0; $i -lt $Runs; $i++) {

  # --- T1: config resolution precedence (session > radio > global) ---
  $G = RR 2400 5900; $R = RR 2400 5900; $S = RR 2400 5900
  $cfg = Join-Path $tmp 't1.conf'
  "[global]`nfreq_mhz = $G`n[radio r1]`nbackend=mock`nfreq_mhz=$R`n[radio r2]`nbackend=mock" |
    Set-Content -LiteralPath $cfg
  Parse-Config $cfg
  $script:SESSION = @{}; $script:ACTIVE = 'r1'
  $radioVal = Resolve-Key freq_mhz '-'
  $script:SESSION['freq_mhz'] = "$S"
  $sessVal = Resolve-Key freq_mhz '-'
  $script:SESSION = @{}; $script:ACTIVE = 'r2'
  $globalVal = Resolve-Key freq_mhz '-'
  Assert 'T1' (($radioVal -eq "$R") -and ($sessVal -eq "$S") -and ($globalVal -eq "$G")) `
    "radio=$radioVal(want $R) sess=$sessVal(want $S) global=$globalVal(want $G)"

  # --- T2: per-backend freq validation ---
  $be = @('wifi-overlay','sdr','mock')[$rng.Next(0,3)]
  $c = Caps-For $be
  $f = RR 0 7000
  $script:SESSION = @{}; $script:ACTIVE = 'r'
  $ok = Validate-Freq $be $f 6>$null
  $inRange = ($f -ge $c.min -and $f -le $c.max)
  Assert 'T2' ($ok -eq $inRange) "$be f=$f inRange=$inRange validated=$ok"

  # --- T3: capability table sanity (ranges + mac field well-formed) ---
  $macok = @('full','limited','unknown') -contains $c.mac
  Assert 'T3' (($c.min -le $c.max) -and $macok) "$be min=$($c.min) max=$($c.max) mac=$($c.mac)"

  # --- T5: fleet/profile enumeration count ---
  $n = RR 1 6
  $cfg5 = Join-Path $tmp 't5.conf'
  $sb = New-Object System.Text.StringBuilder
  for ($k = 1; $k -le $n; $k++) { [void]$sb.AppendLine("[radio r$k]`nbackend=mock") }
  $sb.ToString() | Set-Content -LiteralPath $cfg5
  Parse-Config $cfg5
  $count = @(Get-Profiles).Count
  Assert 'T5' ($count -eq $n) "n=$n profiles=$count"
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("TOTAL  pass={0}  fail={1}" -f $pass, $fail)
if ($fail -gt 0) {
  Write-Host "FAILURES (first 10):"
  $details | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
  Write-Host "RESULT: FAIL"
  exit 1
}
Write-Host "RESULT: PASS — no defects across $pass randomized assertions"
exit 0
