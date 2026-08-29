# radioctl + radio-inject — heterogeneous radio control plane & L2.5 injector

A control-plane CLI and raw-injection tool for running custom, disparate Layer-2
protocols (e.g. an 802.22-derived scheduled MAC) over a fleet of heterogeneous radios —
from a least-constrained "L2.5" overlay on Wi-Fi silicon up to a fully custom MAC/PHY
SDR — with a hardware-free validation path so the software is provable without a radio in
the loop.

---

## BLUF

- **What it is.** One operator CLI (`radioctl`, in bash **and** PowerShell) built on a
  Hardware Abstraction Layer with four interchangeable backends (`mock`, `wifi-overlay`,
  `wifi-mac`, `sdr`), plus `radio-inject`, a stdlib-only raw 802.11 broadcast injector
  that puts your L2.5 PDUs on the air with the hardware MAC neutralised (broadcast +
  radiotap NOACK/NOSEQ, so **your** L2 owns reliability and ordering).
- **Why this shape.** The same command surface and the same netdev seam span every radio
  class, so you validate L2 logic on a real-but-wrong radio (surrogate PHY) long before
  the TVWS SDR path exists, then swap the PHY underneath without touching the upper layers.
- **Verification status.** The software logic is proven by a Monte Carlo campaign:
  **20,765 randomized assertions, 0 defects** on every executable path (`radio-inject`
  20,015 + `radioctl.sh` 750). `radioctl.ps1` is parity-verified (29/29 backend functions,
  identical command surface) with a Windows harness to confirm on real PowerShell. A
  GitHub Actions **regression gate** re-runs the whole campaign on every push.
- **What is not yet proven.** Live RF behaviour on hardware — injection over the air,
  no-ACK/no-retry on real silicon, sequence ownership, and slot-timing jitter. A concrete
  **real-world validation protocol (E1–E6)** is specified below; it needs the ath9k/mt76
  hardware in `HARDWARE_BOM.md`.
- **Governing hardware caveat.** MediaTek/`mt76` is the modern open OpenWrt platform and
  supports injection, but it does **not** restore ath9k's register-level MAC-timing
  control (firmware offload). Modern APs = surrogate-PHY + RX-diversity nodes; reserve
  ath9k (x86 + AR9280/AR9380) or the SDR path for deterministic slot timing.

---

## Architecture

```
        your L2 (scheduled MAC / ARQ)  ── 802.22-derived, PHY-agnostic
                     |
        +------------+-------------+  netdev seam (TUN/TAP) — planned upper edge
        |          radioctl        |  HAL: one command surface, N backends
        |  mock | wifi-overlay | wifi-mac | sdr
        +----+----------+----------+-------+--+
             |          |          |       |
   loopback  |   radio-inject (SEAM #1)    |  radio-phy (SEAM #2, SDR)
  (airwaves) |   raw 802.11 bcast+NOACK    |  SoapySDR/UHD/GNU Radio
             |                             |
        gps / WSDB (SEAM #3, beta) — geolocation gate before any antenna port
```

- **HAL / backends.** `mock` (no hardware, loopback), `wifi-overlay` (ath10k/LiteBeam
  class — MAC control *limited*, closed firmware), `wifi-mac` (ath9k class — deeper
  queue/backoff control), `sdr` (SoapySDR — full MAC/PHY, TVWS-capable). Same verbs for
  all: `probe / configure / up / down / inject / capture / status`.
- **Seams.** SEAM #1 `radio-inject` (implemented); SEAM #2 `radio-phy` (SDR streaming
  stub); SEAM #3 `gps`/white-space-DB (beta, compliance-gating).
- **Fleet & diversity.** Every radio is a named profile; `fleet-capture` fans a capture
  across the fleet so each receiver reports independently — the RX-diversity substrate.

---

## Components

| File | What it is |
|---|---|
| `radioctl.sh` / `radioctl.ps1` | Control-plane CLI (bash / PowerShell), feature-parity |
| `radio-inject` | Stdlib-only raw 802.11 broadcast injector + monitor RX (SEAM #1) |
| `radios.conf` | Fleet definition (INI; `[global]` + one `[radio NAME]` per device) |
| `HARDWARE_BOM.md` | Hardware matrix / BOM (good/better/best, MAC-control caveat per option) |
| `montecarlo_radio_inject.py` | Property-based Monte Carlo tests for `radio-inject` |
| `montecarlo_radioctl.sh` / `.ps1` | Randomized scenario tests for the CLIs |
| `MONTECARLO_REPORT.md` | Full verification report |
| `ACCEPTANCE_LOG.md` | Acceptance log (BLUF, actions, Q&A ledger, frame anatomy) |
| `.github/workflows/regression.yml` | Standing regression gate (CI) |

---

## Quickstart

```bash
# Linux
bash radioctl.sh --config radios.conf            # interactive REPL
bash radioctl.sh --config radios.conf doctor     # per-backend dependency check
python3 radio-inject selftest                    # hardware-free acceptance check
```
```powershell
# Windows
.\radioctl.ps1 -Config radios.conf
.\radioctl.ps1 -Config radios.conf doctor
```

No-hardware smoke test (exercises L2 + RX-diversity with zero radios):
```
use sim-a
up
inject CAFED00D
use sim-b
up
capture 1              # sim-b hears sim-a on the shared 5200 MHz broadcast domain
fleet-capture 1        # every radio reports what it independently heard
```

Live injection on an ath9k/mt76 monitor interface:
```
radio-inject tx --iface mon0 --hex <PDU> --broadcast --magic 5241444F -v
radio-inject rx --iface mon0 --magic 5241444F -v        # on a peer
```

---

## Validation — Monte Carlo (software logic)

Property-based testing: each scenario draws thousands of randomized inputs from the
realistic input space and asserts an invariant that must hold. Full detail and the
frame-anatomy table are in `MONTECARLO_REPORT.md`.

| Component | Assertions | Defects | Coverage |
|---|---:|---:|---|
| `radio-inject` (Python) | 20,015 | 0 | build/parse round-trip, overlay-magic filter, pcap (DLT 127), sequence trains, strip-FCS, helper fns, edge cases (empty->2304 B, seq wrap, all TX flags) |
| `radioctl.sh` (bash) | 750 | 0 | resolution precedence, per-backend freq gating, mock broadcast-domain loopback, dispatch robustness, fleet enumeration |
| `radioctl.ps1` (PowerShell) | parity | — | not executed in authoring env; 29/29 backend fns + identical command surface; run `montecarlo_radioctl.ps1` on Windows |

Reproduce:
```bash
python3 montecarlo_radio_inject.py 20000 0xC0FFEE   # RESULT: PASS
bash    montecarlo_radioctl.sh 150                   # RESULT: PASS
```
```powershell
pwsh -File montecarlo_radioctl.ps1 -Runs 2000        # run on Windows
```

**Scope of this tier:** proves the software (framing, sequencing, config resolution,
frequency gating, loopback) is defect-free. It does **not** test live RF — that is the
next tier, below.

---

## Real-world radio validation (experiment protocol)

The Monte Carlo tier proves the *code*; this tier proves the *approach on silicon*. Each
experiment has a hypothesis, a setup using `radioctl` + `radio-inject`, a metric, and an
acceptance threshold. Run in a shielded/confined space; for any TVWS antenna port, wire
SEAM #3 (geolocation -> white-space-DB) first.

Recommended minimum rig: two nodes of the same chipset (start with **ath9k**, then repeat
on **mt76**) as `wifi-mac` backends, plus a third node in monitor as an independent
observer. Tag all frames with a magic (`--magic 5241444F`) so RX filters overlay traffic
from ambient Wi-Fi.

### E1 — Injection reachability (baseline)
- **Hypothesis.** `radio-inject` broadcast frames are received over the air and survive the magic filter.
- **Setup.** Node A `wifi-mac` up on channel X; Node B monitor on X.
- **Procedure.** `radio-inject tx --iface monA --hex <PDU> --broadcast --magic 5241444F --count 1000 --interval 0.01`; on B `radio-inject rx --iface monB --magic 5241444F --pcap b.pcap`.
- **Metric.** Frame delivery ratio (received/1000) vs attenuation (step attenuator or distance).
- **Accept.** >=99% at low attenuation; monotonic, graceful roll-off as attenuation rises.

### E2 — No-ACK / no-retry confirmation
- **Hypothesis.** Broadcast + radiotap NOACK means the hardware neither ACKs nor retries; your ARQ is the only reliability layer.
- **Setup.** Observer node in monitor capturing A's transmissions.
- **Procedure.** Inject a known count; in the observer pcap, count retransmissions (retry bit / duplicate seq) and any ACK frames addressed to A.
- **Metric.** Retry count and ACK count attributable to injected frames.
- **Accept.** 0 hardware retries and 0 ACKs for injected broadcast frames.

### E3 — Sequence ownership (the mt76-vs-ath9k differentiator)
- **Hypothesis.** With NOSEQ the injected 802.11 sequence numbers survive to the air; without it (or on firmware that overrides), they don't.
- **Setup.** A injects a known ascending seq train; observer captures.
- **Procedure.** `tx --seq 100 --count 500` with `--overwrite-seq` off, then repeat with it on; compare captured seq fields to injected.
- **Metric.** Sequence-preservation rate (captured seq == injected seq).
- **Accept.** ath9k ~100% preserved with NOSEQ; **record** the mt76 rate — a low rate quantifies the BOM's MAC-control caveat and tells you whether slot ordering can live in the 802.11 seq field on that platform.

### E4 — Slot-timing jitter (load-bearing for the scheduled MAC)
- **Hypothesis.** The platform can hold inter-frame timing tight enough for slot boundaries.
- **Setup.** A injects at a target interval; timestamp source = observer radiotap TSFT (or an SDR/scope on the band for ground truth).
- **Procedure.** `tx --count 5000 --interval <T>` for several T (e.g. 1 ms, 5 ms, 20 ms); measure actual inter-frame gaps. Compare userspace-only, an `hrtimer` kernel path, and (later) an in-driver scheduler.
- **Metric.** Jitter = standard deviation of inter-frame gap; also worst-case deviation.
- **Accept.** Jitter <= a set fraction (e.g. <=10%) of your intended slot guard time. This experiment decides whether a given host/radio can carry your scheduled MAC at all — it is the real acceptance test for slot timing, and where MIPS consumer APs are expected to fail and x86 + ath9k to pass.

### E5 — RX diversity gain (validates the fleet premise)
- **Hypothesis.** Multiple independent receivers raise combined delivery ratio over the best single receiver.
- **Setup.** A injects; N observer nodes (`fleet-capture`) capture simultaneously, physically separated.
- **Procedure.** `fleet-capture` (or per-node `radio-inject rx --pcap`) during an injection run at moderate attenuation; compute per-node and selection-combined delivery ratios offline.
- **Metric.** Diversity gain = combined DR - best single-node DR.
- **Accept.** Combined DR >= best single DR; gain grows with node separation. Confirms `fleet-capture` is a real diversity substrate, not just parallel logging.

### E6 — Surrogate->hardware parity (validates surrogate-first)
- **Hypothesis.** A scenario that passes in the `mock` backend predicts L2 behaviour on hardware.
- **Setup.** The same scenario script (inject sequence, expected RX set) run against `mock` and against `wifi-mac` hardware.
- **Procedure.** Diff the L2-visible outcome (frame counts, ordering, magic-filtered RX set) between mock and hardware.
- **Metric.** Behavioural delta at the L2 boundary (should be zero for framing/ordering; RF loss shows only as delivery ratio, not logic divergence).
- **Accept.** No L2-logic divergence between surrogate and hardware; differences confined to RF delivery ratio. This is what justifies developing against `mock` in CI.

**Recording.** Archive every run's pcaps (`--pcap`) and append results to `ACCEPTANCE_LOG.md`
so the hardware tier accumulates the same audit trail as the software tier.

---

## Hardware

Summary; full matrix with the MAC-control caveat per option in `HARDWARE_BOM.md`.

- **Top two modded APs:** OpenWrt One (MT7981B, ~$89, unbrickable reference board) and
  GL.iNet Flint 2 (MT7981B, ~$150, more headroom). Both `mt76`, both run `radio-inject`.
- **Max MAC control:** x86 host + ath9k card (AR9280/AR9380) — still the pick for
  deterministic slot timing despite being 802.11n.
- **RX-diversity nodes:** several Alfa AWUS036ACM (MT7612U) across one host.
- Avoid Broadcom for Wi-Fi under OpenWrt; verify exact hardware revision on the OpenWrt
  Table of Hardware before buying.

---

## CI — standing regression gate

`.github/workflows/regression.yml` runs on every push/PR/dispatch:

- **linux** (ubuntu-latest): `radio-inject selftest`, `montecarlo_radio_inject.py`,
  `montecarlo_radioctl.sh`, plus informational shellcheck.
- **windows** (windows-latest): `radioctl.ps1 doctor` smoke + `montecarlo_radioctl.ps1`.
- **gate**: green only if both matrices pass.

Assumes files at repo root; adjust paths if nested. This turns the Monte Carlo campaign
into a merge gate so no change can regress the verified logic.

---

## Roadmap / open decisions

1. **Testbed layer** (next): drive traffic at `radio-inject`'s frame layer (buildable
   now) vs at the TUN/TAP netdev (runs your real MAC/ARQ in the loop; needs the netdev
   seam first).
2. **Netdev seam**: TUN/TAP upper edge so surrogate-PHY and SDR-PHY are drop-in
   interchangeable under one L2.
3. **SEAM #2 `radio-phy`**: SDR TX/RX bridge for the real TVWS PHY.
4. **SEAM #3 `gps`/WSDB**: geolocation gate before any antenna port (beta).

---

## Compliance

`radio-inject` prints a compliance banner on live transmit: emission must be within
authorized/confined spectrum, and TVWS operation is geolocation/WSDB-gated (SEAM #3)
before any antenna port. The tool does not hard-block (shielded-lab use is the intended
path) but the reminder is always emitted. This project takes the operator's stated
confinement/authorization at face value; lawful operation is the operator's responsibility.

---

_Naming is functional; rename freely to fit your conventions. Last updated: this session._
