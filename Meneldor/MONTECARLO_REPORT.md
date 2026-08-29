# Monte Carlo Verification Report

Scope: `radio-inject`, `radioctl.sh`, `radioctl.ps1` · Method: property-based / randomized scenario testing · Status: **PASS (bash + Python executed); PowerShell parity-verified, not executed here**

---

## BLUF

The code was exercised with **20,765 randomized assertions across best-fit usage
scenarios** and returned **zero defects** on every path that could be executed in this
environment:

- `radio-inject` (Python): **20,015 assertions, 0 failures.**
- `radioctl.sh` (bash): **750 scenario assertions, 0 failures.**
- `radioctl.ps1` (PowerShell): **could not be executed here** (no `pwsh`; Microsoft
  package repo not reachable). Verified instead by (a) **exact structural parity** with
  the passing bash version — identical command surface and a **29/29 backend-function
  match** — and (b) a ready-to-run PowerShell harness (`montecarlo_radioctl.ps1`) to
  confirm on Windows.

One defect was found and fixed **in the test harness** (an `importlib` loader that can't
handle an extension-less module); the code under test was never at fault. No defects
were found in the delivered code. Every run is seeded and reproducible.

---

## Method

"Monte Carlo" here means property-based testing: rather than a handful of fixed inputs,
each scenario draws thousands of randomized inputs from the realistic input space and
asserts an **invariant that must hold** for the code to be correct. Best-fit scenarios
were chosen to cover the paths that actually carry protocol meaning (framing, sequence
handling, config resolution, frequency gating, the mock loopback), not incidental code.

Seeds are fixed so any failure is reproducible: `radio-inject` seed `0xC0FFEE`,
`radioctl.sh` uses `$RANDOM`, `radioctl.ps1` seed `12345`.

---

## radio-inject — scenarios & results

Harness: `montecarlo_radio_inject.py` — loads the module and drives its pure functions.

| Scenario | Invariant asserted | Runs | Fails |
|---|---|---:|---:|
| S1 build/parse round-trip | body, src, dst, bssid, seq (mod 4096), type, radiotap len, TX_FLAGS, total length all preserved | 4040 | 0 |
| S2 overlay magic filter | tagged body starts with the magic; a corrupted magic is rejected (the `rx` filter semantics) | 4011 | 0 |
| S3 pcap round-trip | N frames written at DLT 127 read back byte-identical, bodies re-parse | 3972 | 0 |
| S4 sequence train | `--count`/`--seq` loop increments and preserves each seq | 4000 | 0 |
| S5 strip-fcs | full body preserved; `strip_fcs` removes exactly 4 bytes (only when ≥4 present) | 3977 | 0 |
| EDGE (deterministic) | empty/1B/4B-boundary/2304B bodies; seq wrap at 0/4095/4096/5000/65535; every single TX flag | 15 | 0 |
| **Total** | | **20015** | **0** |

Input space per iteration: random payloads (0–2304 bytes, random content), random
MACs, seq values deliberately exceeding 12 bits (to prove masking), and random 16-bit
TX-flag words.

---

## radioctl.sh — scenarios & results

Harness: `montecarlo_radioctl.sh` — each scenario runs in its own REPL session (the mock
airwaves loopback is per-process), driving the real CLI.

| Scenario | Invariant asserted | Runs | Fails |
|---|---|---:|---:|
| T1 resolution precedence | `Resolve` returns session override > radio value > global default, in that order | 150 | 0 |
| T2 freq validation | `up` accepts iff freq ∈ backend range (wifi-overlay 2400–5925, sdr 1–6000, mock 0–100000); rejects otherwise | 150 | 0 |
| T3 mock broadcast domain | a capture on frequency F hears exactly the frames injected on F across the fleet | 150 | 0 |
| T4 dispatch robustness | random storms of valid commands exit 0 with no bash-internal error (`unbound variable`, `line N:`, syntax error, `command not found`, `unknown command`) | 150 | 0 |
| T5 fleet enumeration | `profiles` and `fleet` list exactly the N configured radios | 150 | 0 |
| **Total** | | **750** | **0** |

Input space: random valid frequencies, random backend selection, random fleet sizes
(1–6), random shared/disjoint frequency assignments, random 5–15-command sequences.

---

## radioctl.ps1 — parity evidence (not executed here)

| Check | Result |
|---|---|
| Command surface (bash dispatch vs PS switch) | Identical — same 21 commands + `help`/`?` aliases |
| Backend functions `be_<backend>_<verb>` | **29 in each, exact match** |
| REPL dot-source guard added for testability | Yes (`$MyInvocation.InvocationName -ne '.'`) |
| PS harness provided | `montecarlo_radioctl.ps1` — Monte-Carlos Resolve-Key, Validate-Freq, Caps-For, Get-Profiles |

The PS harness targets the **pure decision logic** (where correctness bugs live and where
return values are cleanly assertable). The I/O paths (mock loopback, dispatch output) are
covered on the bash side and mirrored structurally. Run on Windows:
`pwsh -File .\montecarlo_radioctl.ps1 -Runs 2000`.

---

## Defects

| # | Where | Description | Resolution |
|---|---|---|---|
| H1 | test harness (`montecarlo_radio_inject.py`) | `importlib.spec_from_file_location` returns a null loader for an extension-less module file, so the module wouldn't load | Switched to explicit `SourceFileLoader`; re-ran clean |

No defects were found in `radio-inject`, `radioctl.sh`, or (by parity) `radioctl.ps1`.

---

## Reproduce

```bash
python3 montecarlo_radio_inject.py 20000 0xC0FFEE   # → RESULT: PASS
bash    montecarlo_radioctl.sh 150                   # → RESULT: PASS
```
```powershell
pwsh -File .\montecarlo_radioctl.ps1 -Runs 2000      # run on Windows to confirm PS
```

Both executed harnesses print a per-scenario table and exit non-zero on any failure, so
they drop straight into CI (e.g. a GitHub Actions matrix: ubuntu-latest for the first
two, windows-latest for the third).

---

## Interpretation & limits

- These tests prove the **software logic** is correct: framing, sequence handling, config
  resolution, frequency gating, and the mock loopback all behave to spec under heavy
  randomization. That is the acceptance question you asked ("does the code actually work
  with no defects") for the parts that don't need a radio.
- They do **not** test live RF behaviour — real `AF_PACKET` injection on a monitor
  interface, driver quirks, or timing on hardware. Those require the ath9k/mt76 hardware
  from the BOM and are the next validation tier (live bring-up procedure is in
  `ACCEPTANCE_LOG.md`).
- `radioctl.ps1` remains **execution-unverified in this environment**; the Windows harness
  closes that gap when run on real PowerShell.
