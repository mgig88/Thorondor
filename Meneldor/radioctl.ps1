#requires -Version 5.1
<#
  radioctl.ps1 — heterogeneous radio control plane (Windows / PowerShell)

  Feature-parity with radioctl.sh. One operator CLI spanning a fleet of radios
  via a Hardware Abstraction Layer. Backends (identical command surface):
    mock          no hardware; loopback "airwaves" for L2/CI bring-up
    wifi-overlay  ath10k / LiteBeam class — L2.5 injection, MAC control: limited
    wifi-mac      ath9k class            — deeper queue/backoff control
    sdr           SoapySDR               — full freq range incl. TVWS, full MAC/PHY

  This is a CONTROL PLANE: it drives iw/ip/SoapySDR (typically over SSH to a
  Linux radio host, or against local SoapySDR on Windows) and hands raw PHY glue
  to helper seams (see README). It does not itself do raw 802.11 injection.

  Usage:
    .\radioctl.ps1                          # interactive REPL
    .\radioctl.ps1 -Config radios.conf doctor
    .\radioctl.ps1 use r1 up
#>
[CmdletBinding()]
param(
  [string]$Config = $(if ($env:RADIOCTL_CONFIG) { $env:RADIOCTL_CONFIG } else { 'radios.conf' }),
  [string]$Profile,
  [Parameter(ValueFromRemainingArguments=$true)] [string[]]$Args
)

Set-StrictMode -Off
$script:VERSION  = '0.1.0'
$script:ACTIVE   = ''
$script:DRYRUN   = 'auto'                 # auto|on|off
$script:CFG      = @{}                     # "section`tkey" => value
$script:SESSION  = @{}
$script:STATE    = @{}
$script:SECTIONS = New-Object System.Collections.Generic.List[string]
$script:BACKENDS = @('mock','wifi-overlay','wifi-mac','sdr')
$script:AIRWAVES = Join-Path ([IO.Path]::GetTempPath()) ("radioctl-airwaves.$PID.tsv")
if (-not (Test-Path $script:AIRWAVES)) { New-Item -ItemType File -Path $script:AIRWAVES -Force | Out-Null }

# ---- output -----------------------------------------------------------------
function Info([string]$m){ Write-Host $m -ForegroundColor DarkGray }
function Ok  ([string]$m){ Write-Host $m -ForegroundColor Green }
function Warn([string]$m){ Write-Host $m -ForegroundColor Yellow }
function Err ([string]$m){ Write-Host $m -ForegroundColor Red }
function Have([string]$c){ [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function San ([string]$s){ $s -replace '-','_' }

function Run {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Cmd)
  $mode = $script:DRYRUN
  if ($mode -eq 'auto') { $mode = if (Have $Cmd[0]) { 'on' } else { 'off' } }
  if ($mode -eq 'off') { Info "[dry-run] $($Cmd -join ' ')"; return }
  Info "+ $($Cmd -join ' ')"
  & $Cmd[0] @($Cmd[1..($Cmd.Count-1)])
}

# ---- config parsing ---------------------------------------------------------
function Parse-Config([string]$f){
  $script:CFG = @{}; $script:SECTIONS.Clear()
  if (-not (Test-Path $f)) { Warn "config '$f' not found — globals/defaults only"; return }
  $sect = 'global'
  foreach ($raw in Get-Content -LiteralPath $f) {
    $line = ($raw -replace '#.*$','').Trim()
    if ($line -eq '') { continue }
    if ($line -match '^\[(.+)\]$') { $sect = $Matches[1].Trim(); $script:SECTIONS.Add($sect); continue }
    $i = $line.IndexOf('='); if ($i -lt 0) { continue }
    $key = $line.Substring(0,$i).Trim(); $val = $line.Substring($i+1).Trim()
    $script:CFG["$sect`t$key"] = $val
  }
}

function Resolve-Key([string]$key,[string]$def=''){
  if ($script:SESSION.ContainsKey($key)) { return $script:SESSION[$key] }
  if ($script:ACTIVE -and $script:CFG.ContainsKey("radio $($script:ACTIVE)`t$key")) { return $script:CFG["radio $($script:ACTIVE)`t$key"] }
  if ($script:CFG.ContainsKey("global`t$key")) { return $script:CFG["global`t$key"] }
  return $def
}
function Get-Profiles { $script:SECTIONS | Where-Object { $_ -like 'radio *' } | ForEach-Object { $_.Substring(6) } }

# ---- capability table -------------------------------------------------------
function Caps-For([string]$be){
  switch ($be) {
    'mock'         { @{min=0;    max=100000; mac='full';    needs=@()} }
    'wifi-overlay' { @{min=2400; max=5925;   mac='limited'; needs=@('iw','ip')} }
    'wifi-mac'     { @{min=2400; max=5925;   mac='full';    needs=@('iw','ip')} }
    'sdr'          { @{min=1;    max=6000;   mac='full';    needs=@('SoapySDRUtil')} }
    default        { @{min=0;    max=0;      mac='unknown'; needs=@()} }
  }
}
function Validate-Freq([string]$be,[double]$f){
  $c = Caps-For $be
  if ($f -lt $c.min -or $f -gt $c.max) { Err "freq $f MHz outside backend '$be' range $($c.min)-$($c.max) MHz"; return $false }
  return $true
}
function BwFlag([string]$bw){ switch ($bw) { '40'{'HT40+'} '80'{'80MHz'} default {'HT20'} } }

# =============================================================================
# BACKEND VERBS.  Lookup: be_<backend>_<verb>  then  be_default_<verb>
# =============================================================================
function be_default_caps {
  $be = Resolve-Key backend mock; $c = Caps-For $be
  "backend      : $be"
  "freq range   : $($c.min)-$($c.max) MHz"
  "MAC control  : $($c.mac)"
  "external deps : $(@($c.needs) -join ', ')"
}
function be_default_status {
  "radio        : $(if($script:ACTIVE){$script:ACTIVE}else{'<none>'})"
  "backend      : $(Resolve-Key backend mock)"
  "iface        : $(Resolve-Key iface -)"
  "freq / bw    : $(Resolve-Key freq_mhz -) MHz / $(Resolve-Key bw_mhz -) MHz"
  "mode / mac   : $(Resolve-Key mode -) / $(Resolve-Key mac -)"
  "state        : $(if($script:STATE.up){$script:STATE.up}else{'down'})"
}
function be_default_probe     { Warn "probe not implemented for backend '$(Resolve-Key backend)'" }
function be_default_configure { Info 'configure: no backend-specific action' }
function be_default_up        { $script:STATE.up='up'; Ok 'up' }
function be_default_down      { $script:STATE.up='down'; Ok 'down' }
function be_default_inject    { Warn 'inject not implemented for this backend' }
function be_default_capture   { Warn 'capture not implemented for this backend' }

# ---- mock -------------------------------------------------------------------
function be_mock_probe { Ok 'mock radio present (virtual). No hardware required.' }
function be_mock_up    { $script:STATE.up='up'; Ok "mock up @ $(Resolve-Key freq_mhz 5200) MHz" }
function be_mock_down  { $script:STATE.up='down'; Ok 'mock down' }
function be_mock_inject {
  param([string]$data='DEADBEEF')
  $ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  "$ts`t$($script:ACTIVE)`t$(Resolve-Key freq_mhz 5200)`t$data" | Add-Content -LiteralPath $script:AIRWAVES
  Ok "injected $($data.Length) nibbles onto shared airwaves (broadcast domain)"
}
function be_mock_capture {
  param([int]$secs=2)
  $f = Resolve-Key freq_mhz 5200
  Info "listening ${secs}s on $f MHz (mock) ..."
  $heard = Get-Content -LiteralPath $script:AIRWAVES | Where-Object { ($_ -split "`t")[2] -eq $f }
  if ($heard) { $heard | ForEach-Object { $p=$_ -split "`t"; "  heard from $($p[1])  freq=$($p[2])  data=$($p[3])" } }
  else { '  (silence)' }
}

# ---- wifi-overlay (ath10k / LiteBeam) ---------------------------------------
function be_wifi_overlay_probe {
  $iface = Resolve-Key iface wlan0
  if (Have iw) { Run iw dev $iface info } else { Warn 'iw not present (drive a Linux radio host over SSH)' }
  Warn 'MAC control: LIMITED — ath10k lower-MAC is closed firmware. Overlay only.'
}
function be_wifi_overlay_up {
  $be='wifi-overlay'; $iface=Resolve-Key iface wlan0; $mon=Resolve-Key monvif mon0
  $freq=[double](Resolve-Key freq_mhz 5200); $bw=Resolve-Key bw_mhz 20
  if (-not (Validate-Freq $be $freq)) { return }
  Run iw dev $iface interface add $mon type monitor
  Run ip link set $mon up
  Run iw dev $mon set freq $freq (BwFlag $bw)
  Run iw dev $mon set txpower fixed ([int](Resolve-Key txpower_dbm 20) * 100)
  $script:STATE.up='up'; $script:STATE.mon=$mon
  Ok "overlay up on $mon @ ${freq}MHz/${bw}MHz — your ARQ owns reliability (no auto-ACK on bcast)"
}
function be_wifi_overlay_down {
  $mon = if ($script:STATE.mon) { $script:STATE.mon } else { Resolve-Key monvif mon0 }
  Run iw dev $mon del; $script:STATE.up='down'; Ok 'overlay down'
}
function be_wifi_overlay_inject {
  param([string]$data)
  if (-not $data) { Err 'usage: inject <hex>'; return }
  $helper = Resolve-Key inject_helper radio-inject
  $mon = if ($script:STATE.mon) { $script:STATE.mon } else { 'mon0' }
  if (Have $helper) { Run $helper --iface $mon --hex $data --broadcast --no-ack }
  else {
    Warn "SEAM #1: inject helper '$helper' not found."
    Warn 'Raw 802.11 injection lives in a helper (scapy/C), not this shell. It must:'
    Warn '  * frame as broadcast/multicast  -> hardware sends no auto-ACK'
    Warn '  * set radiotap TX_FLAGS = NOACK -> your L2 ARQ/HARQ owns reliability'
    Warn '  * minimise EDCA backoff (CWmin/CWmax small) for deterministic slotting'
    Info "[would inject] iface=$mon hex=$data broadcast no-ack"
  }
}
function be_wifi_overlay_capture {
  param([int]$secs=5)
  $mon = if ($script:STATE.mon) { $script:STATE.mon } else { 'mon0' }
  if (Have tcpdump) { Run tcpdump -i $mon -e -c 50 } else { Warn "tcpdump not present; use the helper RX seam" }
}

# ---- wifi-mac (ath9k) -------------------------------------------------------
function be_wifi_mac_probe {
  be_wifi_overlay_probe
  Warn 'ath9k: full open driver. Queue/backoff tunable via debugfs; consider WMP/MAClet'
  Warn 'for pushing a deterministic slot scheduler onto the NIC.'
}
function be_wifi_mac_up      { be_wifi_overlay_up }
function be_wifi_mac_down    { be_wifi_overlay_down }
function be_wifi_mac_inject  { param([string]$data) be_wifi_overlay_inject $data }
function be_wifi_mac_capture { param([int]$secs=5) be_wifi_overlay_capture $secs }
function be_wifi_mac_configure {
  Info 'ath9k tuning seam: EDCA/queue params under /sys/kernel/debug/ieee80211/phyN/ath9k/'
  Info '  target: CWmin=0 CWmax=0 AIFS=1 to approximate contention-free slotting'
}

# ---- sdr (SoapySDR) ---------------------------------------------------------
function be_sdr_probe {
  if (Have SoapySDRUtil) { Run SoapySDRUtil ("--probe=" + (Resolve-Key device_args '')) }
  else { Warn 'SoapySDRUtil not present — install SoapySDR + device module' }
}
function be_sdr_up {
  $freq=[double](Resolve-Key freq_mhz 600)
  if (-not (Validate-Freq 'sdr' $freq)) { return }
  $script:STATE.up='up'
  Ok "SDR configured @ ${freq}MHz bw=$(Resolve-Key bw_mhz 8)MHz — full MAC/PHY (TVWS-capable)"
  Info "note: geolocation/WSDB query REQUIRED before any real antenna port (see 'gps')"
}
function be_sdr_down { $script:STATE.up='down'; Ok 'SDR stream stopped' }
function be_sdr_inject {
  param([string]$wf)
  if (-not $wf) { Err 'usage: inject <waveform-file|hex>'; return }
  $helper = Resolve-Key phy_helper radio-phy
  if (Have $helper) { Run $helper tx --args (Resolve-Key device_args '') --freq "$(Resolve-Key freq_mhz 600)e6" --input $wf }
  else {
    Warn "SEAM #2: PHY helper '$helper' not found."
    Warn 'SDR TX/RX streaming (UHD/SoapySDR/GNU Radio or custom gateware) lives here.'
    Warn 'This is where your real 802.22-derived OFDMA PHY + spectrum sensing run.'
    Info "[would tx] args=$(Resolve-Key device_args '') freq=$(Resolve-Key freq_mhz 600)MHz input=$wf"
  }
}
function be_sdr_capture {
  param([int]$secs=5)
  $helper = Resolve-Key phy_helper radio-phy
  if (Have $helper) { Run $helper rx --args (Resolve-Key device_args '') --freq "$(Resolve-Key freq_mhz 600)e6" --secs $secs }
  else { Warn "SEAM #2: PHY helper '$helper' missing — SDR RX streaming stub" }
}

# ---- dispatch ---------------------------------------------------------------
function Call-Backend {
  param([string]$verb,[Parameter(ValueFromRemainingArguments=$true)][string[]]$rest)
  $be = Resolve-Key backend mock
  $fn = "be_$(San $be)_$verb"
  if (Get-Command $fn -ErrorAction SilentlyContinue) { & $fn @rest }
  elseif (Get-Command "be_default_$verb" -ErrorAction SilentlyContinue) { & "be_default_$verb" @rest }
  else { Err "no verb '$verb' for backend '$be'" }
}

# =============================================================================
# COMMANDS
# =============================================================================
function Cmd-Help {
@"
radioctl $script:VERSION — heterogeneous radio control plane

  Session / config
    profiles                 list radios defined in $Config
    use <name> | profile <n> select active radio
    show | status            resolved config + runtime state
    set <key> <value>        session override (freq_mhz, bw_mhz, mode, mac, ...)
    set dryrun on|off|auto   force/allow/skip real command execution
    backends                 list backends + capabilities
    doctor                   check external tool availability per backend
    caps                     capabilities of the active backend

  Radio ops (dispatched to active backend)
    probe                    detect/validate hardware
    configure | apply        push freq/bw/mode/MAC params to the radio
    up | down                bring radio interface up / down
    inject <hex|file>        TX (overlay: bcast no-ack; sdr: waveform)
    capture [secs]           RX

  Fleet / diversity
    fleet                    list all radios + up/down
    fleet-capture [secs]     fan out capture across all radios (RX diversity)

  Beta seam
    gps                      geolocation / white-space-DB status (stub)

    help                     this text
    exit | quit
"@
}
function Cmd-Backends {
  '{0,-14} {1,-14} {2,-8} {3}' -f 'BACKEND','FREQ(MHz)','MAC','DEPS'
  foreach ($be in $script:BACKENDS) {
    $c = Caps-For $be
    '{0,-14} {1,-14} {2,-8} {3}' -f $be, "$($c.min)-$($c.max)", $c.mac, ((@($c.needs) -join ' ') -replace '^$','-')
  }
}
function Cmd-Doctor {
  foreach ($be in $script:BACKENDS) {
    "${be}:"
    $needs = (Caps-For $be).needs
    if (-not $needs -or $needs.Count -eq 0) { '  (no external deps)'; continue }
    foreach ($c in $needs) { if (Have $c) { "  [ok]   $c" } else { "  [MISS] $c" } }
  }
}
function Cmd-Use {
  param([string]$name)
  if (-not $name) { Err 'usage: use <name>'; return }
  if ((Get-Profiles) -contains $name) { $script:ACTIVE=$name; $script:STATE=@{}; Ok "active radio: $name  (backend: $(Resolve-Key backend mock))" }
  else { Err "no radio '$name' in $Config. Known: $((Get-Profiles) -join ' ')" }
}
function Cmd-Set {
  param([string]$k,[string]$v)
  if (-not $k) { Err 'usage: set <key> <value>'; return }
  if ($k -eq 'dryrun') { $script:DRYRUN=$v; Ok "dryrun=$($script:DRYRUN)" }
  else { $script:SESSION[$k]=$v; Ok "session: $k=$v" }
}
function Cmd-Fleet {
  '{0,-12} {1,-14} {2}' -f 'RADIO','BACKEND','STATE'
  foreach ($r in Get-Profiles) {
    $be = if ($script:CFG.ContainsKey("radio $r`tbackend")) { $script:CFG["radio $r`tbackend"] } else { 'mock' }
    '{0,-12} {1,-14} {2}' -f $r, $be, '-'
  }
}
function Cmd-FleetCapture {
  param([int]$secs=3)
  Info "RX-diversity capture across fleet (${secs}s each) — each radio reports independently:"
  $save = $script:ACTIVE
  foreach ($r in Get-Profiles) {
    "--- $r ---"; $script:ACTIVE=$r; $script:STATE=@{}; Call-Backend capture $secs
  }
  $script:ACTIVE=$save
}
function Cmd-Gps {
  Warn 'SEAM #3 (beta): geolocation + white-space DB query.'
  Warn 'FCC Part 15 Subpart H: a real antenna port needs GPS fix -> WSDB query -> permitted'
  Warn 'channels/power BEFORE TX. Wire gpsd + a WSDB client here; feed results into configure.'
}

function Dispatch {
  param([string[]]$a)
  if (-not $a -or $a.Count -eq 0) { Cmd-Help; return }
  $cmd = $a[0]; $rest = if ($a.Count -gt 1) { $a[1..($a.Count-1)] } else { @() }
  switch ($cmd) {
    { $_ -in @('help','?') } { Cmd-Help }
    'backends'       { Cmd-Backends }
    'doctor'         { Cmd-Doctor }
    'profiles'       { Get-Profiles }
    { $_ -in @('use','profile') } { Cmd-Use $rest[0] }
    'show'           { be_default_status }
    'status'         { Call-Backend status }
    'set'            { Cmd-Set $rest[0] $rest[1] }
    'caps'           { Call-Backend caps }
    'probe'          { Call-Backend probe @rest }
    { $_ -in @('configure','apply') } { Call-Backend configure @rest }
    'up'             { Call-Backend up @rest }
    'down'           { Call-Backend down @rest }
    'inject'         { Call-Backend inject @rest }
    'capture'        { Call-Backend capture @rest }
    'fleet'          { Cmd-Fleet }
    'fleet-capture'  { Cmd-FleetCapture ([int]($rest[0] | ForEach-Object { if($_){$_}else{3} })) }
    'gps'            { Cmd-Gps }
    { $_ -in @('exit','quit') } { $script:RUN=$false }
    default          { Err "unknown command: $cmd (try 'help')" }
  }
}

function Repl {
  Ok "radioctl $script:VERSION — config: $Config  (type 'help')"
  $script:RUN = $true
  while ($script:RUN) {
    $p = if ($script:ACTIVE) { "radioctl:$($script:ACTIVE)" } else { 'radioctl' }
    $line = Read-Host $p
    if ($null -eq $line -or $line.Trim() -eq '') { continue }
    Dispatch ([regex]::Split($line.Trim(), '\s+'))
  }
}

# ---- entrypoint -------------------------------------------------------------
# Guard: when dot-sourced (. .\radioctl.ps1) the functions load but the REPL does
# not start — this lets a test harness exercise the pure logic. Normal invocation
# (InvocationName != '.') runs as usual.
if ($MyInvocation.InvocationName -ne '.') {
  Parse-Config $Config
  if ($Profile) { Cmd-Use $Profile }
  if ($Args -and $Args.Count -gt 0) { Dispatch $Args } else { Repl }
}
