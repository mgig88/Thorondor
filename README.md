<!-- THORONDOR // component=repo-front-page // stack=both // status=living-doc -->
# Thorondor

Sovereign heterogeneous radio infrastructure. Two networks, one command philosophy —
reuse the wheel where it exists (**802.11**), build from the SDR up where the protocol
forbids reuse (**802.22**). This is the repo landing page: overview **and** index.

> **Change note (this session):** the repo was flattened. The component folders
> `Meneldor/`, `Gwaihir/`, and `Westron/` now sit at the **repo root** (no `thorondor/`
> wrapper), and this file merges the former `thorondor/README.md` overview with the old
> thin root index into one front page. CI path filters and all doc paths were repointed to
> the flat, capitalized layout. See the Acceptance Ledger at the bottom.

---

## BLUF

- **Two networks, one command philosophy.** The **802.11** side reuses the existing wheel
  (mainline Linux + `mac80211` + `ath9k`/`mt76`, OpenWrt, Meneldor on top). The **802.22**
  side is greenfield **by necessity** — no COTS silicon runs TVWS cognitive-radio OFDMA —
  so we own PHY, MAC, and management userspace from the SDR up.
- **Gwaihir (kernel engine).** A Linux kernel module (x86 Ubuntu first, then ARM) that
  presents the 802.22 MAC as a **netdev** and owns **timing-critical lower-MAC scheduling**
  (`hrtimer` slots). All higher-level processes flow through this netdev. Heavy IQ/DSP does
  **not** live in-kernel — it stays in userspace or on the SDR's FPGA.
- **Substrate abstraction.** Gwaihir talks to the radio through a substrate layer that is
  location-transparent: local bus (USB/PCIe/GbE) **or SDR-over-TCP**. Per-substrate
  firmware/gateware and per-arch (x86_64/arm64) module builds are isolated and notated.
- **Westron (shared config model).** One contract expresses both an 802.11 fleet **and** an
  802.22 BS/CPE cell (superframe, service flows, sensing, WSDB/GPS). It is the integration
  seam between the two stacks. Contract + validator live in `Westron/`.
- **Verification.** The Westron validator is gate-able (`--selftest`) and the Meneldor Monte
  Carlo campaign runs in CI, so neither the config contract nor the tooling can silently
  regress.

---

## Repository map

| Path (repo root) | What lives here |
|---|---|
| `README.md` | **This file** — Thorondor overview + index (the GitHub landing page) |
| `ARCHITECTURE.md` | Full two-stack design doc (netdev seam, inherited-vs-custom, 802.22 decomposition) |
| `Meneldor/` | 802.11 control-plane tooling (`radioctl`, `radio-inject`) + its README, tests, and reports |
| `Gwaihir/` | 802.22 kernel engine (design stage) + its README |
| `Westron/` | Shared config contract — JSON Schema + semantic validator + reference config |
| `.github/workflows/` | CI gates (must live here — GitHub only runs workflows from `.github/workflows/`) |

```
Thorondor/                      (repo root)
  README.md                     ← this front page
  ARCHITECTURE.md               ← two-stack design doc
  Meneldor/                     ← 802.11 tooling (radioctl, radio-inject) + docs/tests
    README.md  radioctl.sh  radioctl.ps1  radio-inject  radios.conf
    montecarlo_radio_inject.py  montecarlo_radioctl.sh  montecarlo_radioctl.ps1
    ACCEPTANCE_LOG.md  MONTECARLO_REPORT.md  HARDWARE_BOM.md
  Gwaihir/                      ← 802.22 kernel engine (create this folder — see below)
    README.md
    arch/{x86_64,arm64}/  substrate/{ad936x,lms7002m,discrete}/  transport/{local,tcp}/
  Westron/                      ← shared config contract
    westron.schema.json  validate_westron.py  thorondor.example.json
  .github/workflows/
    regression.yml              ← Meneldor gate     (fires on Meneldor/**)
    config-contract.yml         ← Westron gate      (fires on Westron/**)
```

---

## Where the READMEs live (and why there are several)

GitHub renders the `README.md` of **whichever folder you are viewing**. So each component
folder gets its own front page, and the repo root gets the landing page. They never
collide — they are different files in different folders.

| README | Exact path | Renders as | Scope |
|---|---|---|---|
| Front page | `README.md` | the repo landing page | This overview + index |
| Meneldor | `Meneldor/README.md` | the `Meneldor/` folder page | 802.11 control-plane tooling |
| Gwaihir | `Gwaihir/README.md` | the `Gwaihir/` folder page | 802.22 kernel engine |

`Westron/` intentionally has **no** README — it holds contract files, documented here and in
`ARCHITECTURE.md`. Add one later if you want a per-folder page.

> **Action needed:** the `Gwaihir/` folder does **not exist in the repo yet**. Create it and
> place `Gwaihir/README.md` inside. Everything else already has its home.

---

## The honest line (kept, per standing approach)

| Layer | 802.11 stack | 802.22 stack | Verdict |
|---|---|---|---|
| Host OS + init/scheduler | inherited Linux (Ubuntu x86) | inherited Linux (Ubuntu x86 → ARM) | **Inherit both.** Never rewrite init/kernel-core. |
| Kernel netdev + timing MAC | `mac80211` (inherited) | **Gwaihir (custom .ko)** | Custom only on the 802.22 side |
| Lower MAC / firmware | chip firmware (inherited) | **custom MAC** (kernel timing + FPGA/userspace) | Greenfield by necessity |
| PHY | mt76/ath9k silicon | **custom gateware / soft-PHY on SDR** | Greenfield by necessity |
| Heavy IQ DSP | n/a | **userspace or FPGA — NOT in kernel** | Deliberate boundary |
| Management userspace | Meneldor / `radioctl` | Meneldor-shaped, Westron-driven | Shared philosophy |

The novelty budget goes to PHY + MAC + radio-specific userspace. Host-OS plumbing is
inherited on both sides.

---

## Gwaihir — the kernel engine (summary; full doc in `Gwaihir/README.md`)

A Linux kernel module that (1) registers a **netdev** (`gwa0`, `gwa1`, …) so IP/routing/apps
flow through it like any interface; (2) runs the **timing-critical lower-MAC** (superframe/
slot scheduling on `hrtimer`s) where determinism must live; and (3) shuttles MPDUs to/from
the **PHY** across the substrate layer. It is **not** the PHY — IQ streaming and OFDMA/
sensing DSP run in userspace (GNU Radio / C++) or on the SDR's FPGA.

```
apps / IP / routing
        │  (kernel netdev gwaN)  ← the seam everything flows through
   ┌────▼─────────────────────────┐
   │ Gwaihir .ko                   │  netdev + hrtimer slot scheduler (lower MAC timing)
   │  ├─ MPDU queue / slot map      │
   │  └─ substrate binding          │
   └────┬───────────────┬──────────┘
        │ local bus      │ SDR-over-TCP
   ┌────▼────┐      ┌────▼─────────┐
   │ USB/PCIe │      │ TCP transport │   (location-transparent PHY source)
   └────┬────┘      └────┬─────────┘
        │                 │
   ┌────▼─────────────────▼────┐
   │ PHY: FPGA gateware  OR     │  OFDMA + spectrum sensing (NOT in kernel)
   │      userspace soft-PHY    │
   └────────────────────────────┘
```

---

## COTS SDR support matrix

Role is decided by two questions — **can it TX?** and **does it cover UHF/VHF TV bands
(~54–698 MHz) at ≥6 MHz?** TX-capable + TV-band = **BS/CPE** candidate; RX-only =
**sensing / incumbent-detection / diversity** node.

### BS / CPE capable (TX, TV-band, ≥6 MHz channel)

| SDR | Transceiver family | Freq range | Max BW | Duplex | Interface | Onboard arch | Notes |
|---|---|---|---|---|---|---|---|
| USRP B200 / B210 / B205mini | AD936x | 70 MHz–6 GHz | 56 MHz | full | USB3 | host | Research gold standard |
| USRP E310/E312/E313/E320 | AD936x | 70 MHz–6 GHz | 56 MHz | full | GbE/embedded | **Zynq ARM+FPGA** | Standalone; ARM substrate |
| USRP N300/N310/N320 | AD936x | wide | up to 100+ MHz | full | 10GbE | **Zynq ARM+FPGA** | RFNoC; ARM substrate |
| USRP X310 / X410 | Xilinx/RFSoC | wide | 100+ MHz | full | 10/100GbE | X410 **RFSoC ARM** | High-end |
| USRP N210 (+WBX/SBX) | daughterboard | DC–6 GHz | 25–50 MHz | full | GbE | host | Legacy but capable |
| LimeSDR-USB | LMS7002M | 100 kHz–3.8 GHz | 61.44 MHz | full 2×2 | USB3 | host+FPGA | Covers VHF+UHF |
| LimeSDR Mini 2.0 | LMS7002M | 10 MHz–3.5 GHz | ~30 MHz | full | USB3 | ECP5 FPGA | Compact BS/CPE |
| Fairwaves XTRX | LMS7002M | 30 MHz–3.8 GHz | ~120 MHz | full | PCIe/M.2 | host varies | Embeddable |
| bladeRF 2.0 micro xA4/xA9 | AD9361 | 47 MHz–6 GHz | 56 MHz | full 2×2 | USB3 | Cyclone V FPGA | Covers low-VHF (47 MHz) |
| bladeRF x40 / x115 | LMS6002D | 300 MHz–3.8 GHz | 28 MHz | full | USB3 | FPGA | Legacy; UHF only |
| Epiq Sidekiq (M.2/PCIe) | AD9361 | 70 MHz–6 GHz | 50+ MHz | full | M.2/PCIe | embedded | Embeddable |
| ADALM-PLUTO | AD9363 | 325 MHz–3.8 GHz (70 MHz–6 GHz hacked) | 20 MHz | full | USB2 | **Zynq ARM+FPGA** | UHF stock; VHF needs freq-extension; cheap ARM substrate |
| HackRF One | discrete (MAX2837) | 1 MHz–6 GHz | 20 MHz | **half** | USB2 | host | 8-bit, half-duplex — experiments only (TDD OK) |

### Sensing / RX-only (incumbent detection, RX diversity)

| SDR | Front-end | Freq range | Max BW | Role |
|---|---|---|---|---|
| RTL-SDR (RTL2832U+R820T2) | discrete | 24–1766 MHz | ~2.4 MHz | Cheap sensing; <6 MHz so partial-channel only |
| Airspy R2 / Mini | discrete | 24–1800 MHz | ~10/6 MHz | Sensing |
| SDRplay RSPdx / RSPduo | discrete | 1 kHz–2 GHz | ~10 MHz | Sensing; RSPduo dual-tuner |
| KrakenSDR | 5× coherent RTL | 24–1766 MHz | RX | Coherent sensing / direction-finding / diversity |

Firmware/substrate isolation implied by this matrix: gateware/PHY forks by **transceiver
family** (AD936x · LMS7002M · LMS6002D · discrete); the Gwaihir module forks by **host arch**
(x86_64 · arm64). Both axes are isolated under `Gwaihir/`.

---

## SDR-over-TCP transport

The substrate layer makes the PHY source **location-transparent**: Gwaihir binds to a
substrate descriptor that is either `local` (USB/PCIe/GbE on the same host) or `tcp`
(a remote SDR host). It abstracts over SoapySDR remote (`SoapySDRServer`), UHD-over-network,
and `rtl_tcp` (RX). Westron expresses this per radio as
`substrate.transport = { type: local | tcp, host, port }`.

---

## Shared config model (Westron)

One contract both stacks speak; the integration seam. Full contract, reference config, and
validator are in `Westron/`; the model is specified in `ARCHITECTURE.md`.

- One `radios[]` list; each entry declares `stack: 802.11 | 802.22`.
- 802.11 entries carry fleet fields (iface, freq, bw, mac).
- 802.22 entries carry `role: bs | cpe`, `rf`, `superframe`, `service_flows[]`, `sensing`,
  `wsdb`, plus a `substrate` block (device family, transport local/tcp, arch).
- Validation is **semantic**: freq-in-band, channel-bw ∈ {6,7,8}, superframe = k·frame,
  guard < frame, unique ids, BS→CPE referential integrity, conditional requirements.

```bash
python3 Westron/validate_westron.py Westron/thorondor.example.json
python3 Westron/validate_westron.py --selftest      # gate-able acceptance check
```

---

## CI gates

Both live in `.github/workflows/` (GitHub only runs workflows from there) and are
path-filtered so each fires only on its own component's changes.

| Workflow | Gates | Fires on changes under |
|---|---|---|
| `regression.yml` | Meneldor Monte Carlo campaign (radio-inject + radioctl) | `Meneldor/**` |
| `config-contract.yml` | Westron config validation (fixture battery + reference config) | `Westron/**` |

Run the same checks locally:
```bash
python3 Meneldor/radio-inject selftest
python3 Westron/validate_westron.py --selftest
```

---

## Update policy & Acceptance Ledger

This front page is updated whenever a piece is **tested and accepted**; each accepted change
appends a row below.

| Date | Component | Change | Verification | Status |
|---|---|---|---|---|
| this session | Repo layout | Flattened to `Meneldor/` · `Gwaihir/` · `Westron/` at repo root (no `thorondor/` wrapper); merged former `thorondor/README.md` + thin root index into this single front page; repointed CI path filters + run steps and all doc paths to the flat, capitalized layout | gates re-run green from new paths (radio-inject selftest; Westron 21/21) | **accepted** |
| this session | Westron config model | v0.1 contract (schema + semantic validator + reference config spanning both stacks) | `validate_westron.py --selftest` (valid/invalid fixtures) + validation of `thorondor.example.json` | **accepted** |
| this session | `config-contract.yml` | Hardened: guard that fails CI if the reference config drifts/goes missing | YAML parses; guard reviewed | **accepted** |
| this session | Two-stack architecture | `ARCHITECTURE.md` design doc (netdev seam, inherited-vs-custom, 802.22 decomposition) | design review (no executable artifact) | accepted (design) |
| this session | Gwaihir engine | design + layout + SDR/substrate/arch isolation; `.ko` not yet implemented | design review | design |
