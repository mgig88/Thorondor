#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# montecarlo_radioctl.sh — randomized scenario tests for radioctl.sh.
#
# Drives the real CLI through many randomized best-fit workflows and asserts the
# invariant that must hold for each. Each scenario runs in its own REPL session
# (the mock "airwaves" loopback is per-process). Exits non-zero on any failure.
#
#   ./montecarlo_radioctl.sh [runs_per_scenario]
# -----------------------------------------------------------------------------
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RADIOCTL="$HERE/radioctl.sh"
RUNS="${1:-150}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; declare -A SP; declare -A SF
fail_details=()

pass(){ PASS=$((PASS+1)); SP["$1"]=$(( ${SP["$1"]:-0} + 1 )); }
failr(){ FAIL=$((FAIL+1)); SF["$1"]=$(( ${SF["$1"]:-0} + 1 )); fail_details+=("[$1] $2"); }
rr(){ echo $(( $1 + RANDOM % ($2 - $1 + 1) )); }         # random int in [lo,hi]
hex(){ local n="$1" s=""; while ((n-->0)); do s+=$(printf '%02X' $((RANDOM%256))); done; echo "$s"; }
session(){ local cfg="$1"; shift; printf '%s\n' "$@" | bash "$RADIOCTL" --config "$cfg" 2>&1; }

# --- T1: config resolution precedence (session > radio > global) -------------
t1(){
  local G R S; G=$(rr 2400 5900); R=$(rr 2400 5900); S=$(rr 2400 5900)
  local cfg="$TMP/t1.conf"
  printf '[global]\nfreq_mhz = %s\n[radio r1]\nbackend=mock\nfreq_mhz=%s\n[radio r2]\nbackend=mock\n' "$G" "$R" >"$cfg"
  # radio-level + session override
  local outA freqs
  outA="$(session "$cfg" "use r1" "show" "set freq_mhz $S" "show" "exit")"
  mapfile -t freqs < <(printf '%s\n' "$outA" | grep '^freq / bw' | sed -E 's/.*: ([0-9-]+) MHz.*/\1/')
  # fresh session for global fallback (avoid session-override contamination)
  local outB gfreq
  outB="$(session "$cfg" "use r2" "show" "exit")"
  gfreq="$(printf '%s\n' "$outB" | grep '^freq / bw' | sed -E 's/.*: ([0-9-]+) MHz.*/\1/')"
  if [[ "${freqs[0]:-}" == "$R" && "${freqs[1]:-}" == "$S" && "$gfreq" == "$G" ]]; then
    pass T1
  else
    failr T1 "want radio=$R sess=$S global=$G got radio=${freqs[0]:-?} sess=${freqs[1]:-?} global=${gfreq:-?}"
  fi
}

# --- T2: freq validation accept/reject per backend ---------------------------
t2(){
  local bes=(wifi-overlay sdr mock); local be="${bes[$((RANDOM%3))]}"
  local lo hi
  case "$be" in wifi-overlay) lo=2400; hi=5925;; sdr) lo=1; hi=6000;; mock) lo=0; hi=100000;; esac
  local f; f=$(rr 0 7000)
  local cfg="$TMP/t2.conf"
  printf '[radio r]\nbackend=%s\nfreq_mhz=%s\niface=wlan0\n' "$be" "$f" >"$cfg"
  local out; out="$(session "$cfg" "use r" "up" "exit")"
  local in_range=0; (( f>=lo && f<=hi )) && in_range=1
  if (( in_range )); then
    if grep -q "outside backend" <<<"$out"; then failr T2 "$be freq=$f in-range but rejected"; else pass T2; fi
  else
    if grep -q "outside backend" <<<"$out"; then pass T2; else failr T2 "$be freq=$f out-of-range but accepted"; fi
  fi
}

# --- T3: mock broadcast-domain capture count ---------------------------------
t3(){
  local n; n=$(rr 2 5)
  local cfg="$TMP/t3.conf"; : >"$cfg"
  local freqs=(5200 5180) ; local -a rf=() ; local i F cmds=()
  for ((i=1;i<=n;i++)); do
    F="${freqs[$((RANDOM%2))]}"; rf+=("$F")
    printf '[radio r%d]\nbackend=mock\nfreq_mhz=%s\n' "$i" "$F" >>"$cfg"
  done
  # each radio comes up and injects exactly once
  for ((i=1;i<=n;i++)); do cmds+=("use r$i" "up" "inject $(hex 3)"); done
  # capture on the frequency of radio 1
  local target="${rf[0]}"; cmds+=("use r1" "capture 1" "exit")
  local out heard expect=0
  out="$(session "$cfg" "${cmds[@]}")"
  heard="$(grep -c 'heard from' <<<"$out")"
  for F in "${rf[@]}"; do [[ "$F" == "$target" ]] && expect=$((expect+1)); done
  if [[ "$heard" == "$expect" ]]; then pass T3; else failr T3 "target=$target expect=$expect heard=$heard rf=(${rf[*]})"; fi
}

# --- T4: dispatch robustness (valid command storms never crash) --------------
t4(){
  local cfg="$TMP/t4.conf"
  printf '[radio r1]\nbackend=mock\nfreq_mhz=5200\n[radio r2]\nbackend=mock\nfreq_mhz=5180\n' >"$cfg"
  local pool=("help" "backends" "doctor" "profiles" "fleet" "use r1" "use r2" "show" "status" "caps" "up" "down" "inject $(hex 2)" "capture 1" "gps" "set dryrun on" "fleet-capture 1")
  local k; k=$(rr 5 15); local cmds=(); local j
  for ((j=0;j<k;j++)); do cmds+=("${pool[$((RANDOM%${#pool[@]}))]}"); done
  cmds+=("exit")
  local out ec
  out="$(printf '%s\n' "${cmds[@]}" | bash "$RADIOCTL" --config "$cfg" 2>&1)"; ec=$?
  if (( ec != 0 )); then failr T4 "exit=$ec"; return; fi
  if grep -Eq 'unbound variable|: line [0-9]+:|syntax error|command not found|unknown command' <<<"$out"; then
    failr T4 "error marker in output: $(grep -Eo 'unbound variable|: line [0-9]+:|syntax error|command not found|unknown command' <<<"$out" | head -1)"
  else
    pass T4
  fi
}

# --- T5: fleet/profile enumeration count -------------------------------------
t5(){
  local n; n=$(rr 1 6); local cfg="$TMP/t5.conf"; : >"$cfg"; local i
  for ((i=1;i<=n;i++)); do printf '[radio r%d]\nbackend=mock\n' "$i" >>"$cfg"; done
  local pc fc
  pc="$(bash "$RADIOCTL" --config "$cfg" profiles 2>/dev/null | grep -c '^r[0-9]')"
  fc="$(bash "$RADIOCTL" --config "$cfg" fleet 2>/dev/null | grep -c '^r[0-9]')"
  if [[ "$pc" == "$n" && "$fc" == "$n" ]]; then pass T5; else failr T5 "n=$n profiles=$pc fleetrows=$fc"; fi
}

echo "radioctl Monte Carlo  cli=$RADIOCTL  runs/scenario=$RUNS"
for ((r=0;r<RUNS;r++)); do t1; t2; t3; t4; t5; done

echo
printf '%-6s %8s %8s\n' scenario pass fail
echo "----------------------------"
for s in T1 T2 T3 T4 T5; do printf '%-6s %8s %8s\n' "$s" "${SP[$s]:-0}" "${SF[$s]:-0}"; done
echo "----------------------------"
printf '%-6s %8s %8s\n' TOTAL "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  echo; echo "FAILURES (first 10):"; printf '  %s\n' "${fail_details[@]:0:10}"
  echo; echo "RESULT: FAIL ($FAIL)"; exit 1
fi
echo; echo "RESULT: PASS — no defects across $PASS randomized scenario assertions"; exit 0
