<!-- THORONDOR // component=gwaihir-engine // stack=802.22 // arch=x86_64,arm64 // substrate=any // status=design -->
# Gwaihir — the kernel engine (802.22)

Engine-scoped README. This directory holds **Gwaihir itself** — the Linux kernel module
that carries the 802.22 stack — and nothing else. For the system-wide design see
`../ARCHITECTURE.md`; for the config model it consumes see `../Westron/`.

> **Status: design.** No `.ko` exists yet. This document defines the engine's scope,
> boundaries, directory layout, and build/milestone plan so the code lands correctly when
> it's written. The umbrella Acceptance Ledger (`../README.md`) tracks accepted milestones.
>
> **Placement:** this file goes at `Gwaihir/README.md` — a folder at the **repo root**,
> sibling to `Meneldor/` and `Westron/`. The `Gwaihir/` folder does not exist in the repo
> yet; create it and drop this README in. (Change note: repo flattened to `Gwaihir/` /
> `Meneldor/` / `Westron/` at root — no `thorondor/` wrapper; cross-links updated to suit.)

---

## Scope

Gwaihir is **one thing**: a kernel module that terminates the 802.22 stack upward as a
network interface and owns the timing-critical part of the MAC. Precisely:

1. **netdev registration** — presents `gwa0`, `gwa1`, … so IP/routing/apps flow through it
   exactly like any interface (the seam the rest of the system integrates against).
2. **Timing-critical lower MAC** — superframe/slot scheduling on `hrtimer`s, where
   determinism must live in-kernel.
3. **Substrate binding** — hands scheduled MPDUs to the PHY across a location-transparent
   substrate (local bus **or** SDR-over-TCP) and takes demodulated MPDUs back.

## Explicit non-scope (the boundary that keeps this engine small)

- **Not the PHY.** OFDMA modulation/demodulation and spectrum sensing run in userspace
  (GNU Radio / C++) or on the SDR's FPGA — **never** floating-point DSP in kernel space.
- **Not MAC policy.** Grant arbitration, service-flow policy, and sensing/WSDB decisions can
  live in a userspace policy daemon that programs the module; only timing lives here.
- **Not the config model.** Gwaihir is configured *from* Westron (`../Westron/`); it does
  not define config.
- **Not the architecture.** The two-stack design is `../ARCHITECTURE.md`, at the umbrella
  level, because it spans both stacks — not an engine artifact.

The dividing rule, restated: **timing-critical + packet-path + small → in this module;
compute-heavy + floating-point + large → userspace/FPGA.**

---

## Interfaces

- **Upward:** a standard netdev (`gwaN`). Above this line the system is stack-agnostic — the
  same seam the Wi-Fi stack presents via `mac80211`.
- **Downward:** a substrate descriptor (from Westron: `device`, `transport {local|tcp}`,
  `arch`). The engine does not care where the radio physically is.
- **Sideways:** an optional userspace policy channel (netlink/ioctl/debugfs, TBD) for the
  MAC policy daemon to install slot maps and service-flow grants.

---

## Directory layout

```
Gwaihir/                    ← at the repo root, sibling to Meneldor/ and Westron/
  README.md                 ← this file
  arch/
    x86_64/                 ← bring-up target (Ubuntu x86)
    arm64/                  ← embedded SDR hosts (Pluto, USRP E3xx/N3xx, XTRX carriers)
  substrate/
    ad936x/                 ← AD9361/AD9363/AD9364 glue (USRP B2xx/E3xx, bladeRF 2.0, Pluto, Sidekiq)
    lms7002m/               ← LimeSDR family, XTRX
    discrete/               ← HackRF (and any device-specific bring-up)
  transport/
    local/                  ← USB/PCIe/GbE binding
    tcp/                    ← SDR-over-TCP binding (SoapyRemote / UHD-over-net class)
```

Two orthogonal build axes: **host arch** (`arch/`) and **transceiver family** (`substrate/`),
crossed with the **transport** the substrate uses. A given deployment selects one cell from
each axis; keep files strictly within their cell and never mix stacks in one file.

## Notation

Every file in this directory carries the header tag so CI can route builds per (arch,
substrate, transport):

```
// THORONDOR // stack=802.22 // component=gwaihir-<part> // arch=<x86_64|arm64|any> // substrate=<family|any> // status=<design|draft|accepted>
```

---

## Build & milestone plan (engine-scoped)

x86 first; ARM once the datapath is proven. Each milestone is the acceptance unit that,
when tested, gets logged in the umbrella ledger.

| # | Milestone | Definition of done | Status |
|---|---|---|---|
| G0 | netdev skeleton | `.ko` loads on x86 Ubuntu, registers `gwa0`, `ip link` shows it up/down | design |
| G1 | loopback datapath | frames written to `gwa0` return on `gwa0` (kernel-internal loop) — proves the seam before any PHY | design |
| G2 | hrtimer slot scheduler | TX gated to slot boundaries; measured jitter within budget (ties to real-world experiment E4) | design |
| G3 | substrate binding (local) | MPDUs shuttled to a real SDR PHY over USB/PCIe | design |
| G4 | substrate binding (tcp) | same over SDR-over-TCP; location-transparent | design |
| G5 | arm64 build | module + a substrate cell build and load on an ARM SDR host | design |

**Recommended first step:** G0 → G1. Standing up the netdev and a kernel-internal loopback
gives the whole system a real seam to integrate against *before* the PHY exists — the same
surrogate-first logic that made `radio-inject` and the `mock` backend valuable.

---

## Relationship to the rest of Thorondor

- Configured by **Westron** (`../Westron/`): a `802.22` radio's `substrate` block selects the
  `arch/` + `substrate/` + `transport/` cell this engine loads.
- Integrated via the **netdev seam**: Meneldor/`radioctl`'s `sdr` backend targets `gwaN`
  once the engine is live, exactly as the `wifi-mac` backend targets `wlanN` today.
- Designed in **`../ARCHITECTURE.md`**: read it for the full two-stack picture and the
  inherited-vs-custom rationale.
