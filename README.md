<!-- THORONDOR // component=custom-stack-readme // stack=both // status=living-doc -->
# Thorondor — custom radio infrastructure (Gwaihir engine · Westron config)

Dedicated README for the **purpose-built** part of Thorondor: the custom kernel engine,
SDR substrate support, and the shared config model that replace OpenWrt's nuts-and-bolts
**where the protocol requires it**. This document is **living** — updated every time a
new piece here is tested and accepted (see the Acceptance Ledger at the bottom).

> This is separate from the top-level project README, which covers the OpenWrt-hosted
> 802.11 tooling (Meneldor / `radioctl` / `radio-inject`). Keep the two concerns isolated.

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
  seam between the two stacks. Contract + validator live in `westron/`.
- **Verification carries over.** The Westron validator is gate-able (`--selftest`) and wired
  into CI exactly like the Monte Carlo campaign, so the config contract can't silently
  regress.

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

## Gwaihir — the kernel engine

**What it is:** a Linux kernel module that (1) registers a **netdev** (`gwa0`, `gwa1`, …)
so IP/routing/apps flow through it like any interface; (2) runs the **timing-critical
lower-MAC** (superframe/slot scheduling on `hrtimer`s) where determinism must live; and
(3) shuttles MPDUs to/from the **PHY** across the substrate layer.

**What it is NOT:** it is not the PHY. IQ sample streaming and OFDMA/sensing DSP run in
userspace (GNU Radio / C++) or on the SDR's FPGA. Gwaihir hands the PHY scheduled MPDUs
and timing marks; the PHY hands back demodulated MPDUs. This keeps floating-point DSP out
of kernel space and lets the same engine drive very different PHY substrates.

**Data flow:**
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

**x86 first, ARM next.** Bring-up target is x86 Ubuntu. Because several COTS SDRs embed an
ARM host (Pluto, USRP E3xx/N3xx, XTRX carriers), the module and its build must be
arch-portable; ARM builds are isolated per `gwaihir/arch/<arch>/` (see layout).

---

## COTS SDR support matrix

Goal: support the breadth of COTS SDRs. Role is decided by two questions — **can it TX?**
and **does it cover UHF/VHF TV bands (~54–698 MHz) at ≥6 MHz?** TX-capable + TV-band =
**BS/CPE** candidate; RX-only = **sensing / incumbent-detection / diversity** node.

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

**Firmware/substrate isolation implied by this matrix:** gateware/PHY forks by
**transceiver family** (AD936x · LMS7002M · LMS6002D · discrete), the FPGA fabric differs
per device, and the Gwaihir module forks by **host arch** (x86_64 · arm64). All three axes
are isolated in the layout below.

---

## SDR-over-TCP transport

The substrate layer makes the PHY source **location-transparent**: Gwaihir binds to a
substrate descriptor that is either `local` (USB/PCIe/GbE on the same host) or `tcp`
(a remote SDR host). Established remoting mechanisms this abstracts over: SoapySDR remote
(`SoapySDRServer`), UHD-over-network, and `rtl_tcp` (RX). Westron expresses this per radio
as `substrate.transport = { type: local | tcp, host, port }`. Location transparency here
mirrors the netdev seam: nothing above the substrate layer knows or cares where the radio
physically is.

---

## Repo layout & notation convention (file isolation)

Everything for the custom stack lives under `thorondor/` and never leaks into the
802.11 tooling at repo root.

```
thorondor/
  README.md                     ← this living doc
  ARCHITECTURE.md               ← two-stack design doc
  westron/                      ← shared config model (the contract)
    westron.schema.json         ← canonical machine-readable contract (JSON Schema)
    thorondor.example.json      ← reference config: 802.11 fleet + 802.22 BS/CPE
    validate_westron.py         ← stdlib semantic validator (gate-able: --selftest)
  gwaihir/                      ← kernel engine (design now; .ko to follow)
    arch/x86_64/                ← x86 module build (bring-up target)
    arch/arm64/                 ← ARM module build (Pluto/E3xx/N3xx hosts)
    substrate/ad936x/           ← per-transceiver-family gateware/driver glue
    substrate/lms7002m/
    substrate/discrete/
    transport/local/            ← USB/PCIe/GbE binding
    transport/tcp/              ← SDR-over-TCP binding
```

**Notation header** — every file in the custom stack carries a one-line tag so its stack,
component, arch, and status are self-evident:

```
// THORONDOR // stack=<802.11|802.22|both> // component=<name> // arch=<x86_64|arm64|any> // substrate=<family|any> // status=<design|draft|accepted>
```

Use the comment syntax of the file's language (`//`, `#`, `<!-- -->`). CI can grep this tag
to route lint/build per stack and arch.

---

## Shared config model (Westron)

Westron is the one contract both stacks speak; it is the integration seam. Full contract,
reference config, and validator are in `westron/`; the model is specified in
`ARCHITECTURE.md`. Highlights:

- One `radios[]` list; each entry declares `stack: 802.11 | 802.22`.
- 802.11 entries carry the familiar fleet fields (iface, freq, bw, mac).
- 802.22 entries carry `role: bs | cpe`, `rf` (center/channel-bw/power), `superframe`
  (frame/superframe/guard timing), `service_flows[]`, `sensing`, and `wsdb` (geolocation
  gate) — plus a `substrate` block (device family, transport local/tcp, arch).
- Validation is **semantic**, not just structural: freq-in-band, channel-bw ∈ {6,7,8},
  superframe = k·frame, guard < frame, unique ids, BS→CPE referential integrity, sensing
  threshold required when sensing is enabled, geo required when WSDB is enabled, `substrate`
  required for 802.22.

Run it:
```bash
python3 thorondor/westron/validate_westron.py thorondor/westron/thorondor.example.json
python3 thorondor/westron/validate_westron.py --selftest      # gate-able acceptance check
```

---

## Update policy

This README is updated whenever a piece of the custom stack is **tested and accepted**.
Each accepted change appends a row to the Acceptance Ledger with what was verified and how.

## Acceptance Ledger

| Date | Component | Change | Verification | Status |
|---|---|---|---|---|
| this session | Westron config model | v0.1 contract (schema + semantic validator + reference config spanning both stacks) | `validate_westron.py --selftest` (valid/invalid fixtures) + validation of `thorondor.example.json` | **accepted** |
| this session | Two-stack architecture | `ARCHITECTURE.md` design doc (netdev seam, inherited-vs-custom, 802.22 decomposition) | design review (no executable artifact) | accepted (design) |
| this session | Gwaihir engine | design + layout + SDR/substrate/arch isolation; `.ko` not yet implemented | design review | design |
