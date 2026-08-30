<!-- THORONDOR // component=two-stack-architecture // stack=both // status=design -->
# Two-Stack Architecture — design doc

How Thorondor runs **two disjoint radio stacks under one command philosophy**, and how the
shared config model (Westron) and the netdev seam bind them. This is the design that the
Westron contract implements; read it before extending the contract.

---

## BLUF

Thorondor is not one stack being stripped down — it is **two stacks that meet at a single
upper edge**. The 802.11 stack is inherited (Linux + `mac80211` + `ath9k`/`mt76`); the
802.22 stack is greenfield (custom PHY + MAC + firmware on an SDR) because no COTS silicon
runs it. Both present the **same netdev-shaped edge** upward, so one management layer
(Meneldor, driven by Westron) and eventually one mesh/routing layer sit on top without
knowing which radio is underneath. The netdev seam is the integration contract; Westron is
the configuration contract. Everything else differs by stack.

---

## 1. The two stacks

```
                         ┌──────────────────────────────────────┐
                         │  management + mesh/routing (shared)   │
                         │  Meneldor · Westron-driven            │
                         └───────────────┬──────────────────────┘
                                         │  netdev seam (the integration contract)
              ┌──────────────────────────┴───────────────────────────┐
              │                                                        │
   ┌──────────▼───────────┐                              ┌────────────▼─────────────┐
   │  802.11 stack (INHERIT)│                              │  802.22 stack (GREENFIELD) │
   │                        │                              │                            │
   │  netdev: wlanN         │                              │  netdev: gwaN (Gwaihir)    │
   │  mac80211 (kernel)     │                              │  lower MAC: Gwaihir .ko    │
   │  ath9k / mt76 driver   │                              │   (hrtimer slot scheduler) │
   │  chip firmware         │                              │  PHY: FPGA gateware OR     │
   │  Wi-Fi silicon PHY     │                              │   userspace soft-PHY on SDR│
   │                        │                              │  substrate: local | TCP    │
   └────────────────────────┘                              └────────────────────────────┘
        radioctl wifi-mac backend                             radioctl sdr backend →
        radio-inject (SEAM #1) for L2.5 surrogate work        Gwaihir netdev when live
```

- **802.11 (inherit).** Nothing new below the netdev. `radioctl`'s `wifi-mac`/`wifi-overlay`
  backends and `radio-inject` already exercise this edge for surrogate-PHY validation.
- **802.22 (greenfield).** Everything below the netdev is ours: the Gwaihir kernel module
  (netdev + timing MAC), the PHY (FPGA gateware or userspace soft-PHY), and per-substrate
  firmware. There is no incumbent stack to inherit — the protocol forbids it.

---

## 2. The netdev seam (why both stacks converge)

Each stack terminates upward in a **network interface**: `wlanN` for Wi-Fi (from
`mac80211`), `gwaN` for 802.22 (from Gwaihir). Above that line, packets are just Ethernet-
shaped frames; routing, mesh, IP, and apps are identical regardless of radio. This is the
same seam `radio-inject` was designed to sit under, and the same one the SDR PHY plugs into
when it is ready.

Consequences:
- The surrogate-PHY work is not throwaway — it validates the management layer against the
  *real* seam using cheap Wi-Fi hardware, then the 802.22 PHY slots into the identical edge.
- Meneldor's apply logic targets a netdev, not a chip. `configure/up/down` mean the same
  operation on both stacks; only the backend implementation differs.
- Mesh/routing (future) is written once, above the seam.

---

## 3. Gwaihir — inherited vs custom, precisely

| Concern | Where it lives | Inherited or custom |
|---|---|---|
| netdev registration | Gwaihir `.ko` | custom (thin; models on mac80211 patterns) |
| Slot/superframe timing | Gwaihir `.ko`, `hrtimer` | **custom — the determinism core** |
| MPDU queueing / slot map | Gwaihir `.ko` | custom |
| Substrate binding (local/TCP) | Gwaihir `.ko` + userspace helper | custom (thin) |
| IQ streaming | userspace (UHD/SoapySDR) or FPGA | inherited tooling |
| OFDMA modulation/demod, sensing | userspace soft-PHY **or** FPGA gateware | **custom — the PHY**, not in kernel |
| Host OS, init, process scheduler | Linux/Ubuntu | inherited — never rewritten |

The dividing rule: **timing-critical, packet-path, small → kernel; compute-heavy,
floating-point, large → userspace/FPGA.** Slot boundaries are timing-critical and small, so
they go in the module; OFDMA and sensing are compute-heavy, so they do not.

---

## 4. 802.22 decomposition (what "completely new firmware" actually contains)

Three isolated bodies of work, forked along the axes the SDR matrix exposes:

1. **PHY / gateware** — OFDMA transceiver, TVWS 6/7/8 MHz channelization, spectrum sensing
   with quiet periods. Forks by **transceiver family** (AD936x · LMS7002M · LMS6002D ·
   discrete) and FPGA fabric. Either FPGA gateware (USRP/RFNoC, Lime, bladeRF, Pluto HDL) or
   a userspace soft-PHY (GNU Radio / C++), or a split.
2. **MAC** — connection-oriented, BS-arbitrated, superframe-scheduled (802.22 lineage:
   DOCSIS/802.16 heritage). Timing lives in Gwaihir; policy (grants, service flows, DFS/
   sensing decisions) can live in a userspace daemon that programs the module.
3. **Management userspace** — Westron config, the scheduler policy daemon, the sensing/WSDB
   client, and the GPS feed. Meneldor-shaped; the Wi-Fi backend is its reference
   implementation.

Per-arch (x86_64 bring-up → arm64 for embedded SDR hosts) is a build axis over all three.

---

## 5. Shared config model (Westron) — design

One contract, both stacks. A single `radios[]` array; each entry self-declares its stack.

### 5.1 Entities

- **deployment** — top-level metadata: `name`, schema `version`, optional `geo` (site
  location for WSDB), `defaults`.
- **radio** — one device. Common: `id`, `stack`, `role`, `netdev` (the seam name),
  optional `substrate`. Stack-specific blocks below.
- **802.11 radio** — `iface`, `rf { freq_mhz, bw_mhz }`, `mac { mode }`, `txpower_dbm`.
  (Mirrors today's `radios.conf` fields, now structured.)
- **802.22 radio** — `role: bs | cpe`, `rf { center_mhz, channel_bw_mhz, tx_power_dbm }`,
  `superframe { frame_ms, superframe_ms, guard_us }`, `service_flows[] { id, direction,
  qos, rate_kbps }`, `sensing { enabled, quiet_period_ms, threshold_dbm, incumbents[] }`,
  `wsdb { enabled, db_url, geo }`, and for a BS, `cpes[]` (ids of CPE radios it serves).
- **substrate** (required for 802.22 / any SDR) — `device` (usrp|lime|bladerf|hackrf|pluto|
  rtlsdr|airspy|sdrplay|xtrx|sidekiq|kraken|other), `driver_args`, `arch`
  (x86_64|arm64|any), `transport { type: local|tcp, host?, port? }`.

### 5.2 Semantic rules (the part a schema alone can't enforce)

- **Frequency in band:** 802.11 within backend range; 802.22 `center_mhz` within
  the TV band envelope (≈54–862 MHz) and the SDR's own range.
- **Channelization:** 802.22 `channel_bw_mhz ∈ {6,7,8}`.
- **Superframe sanity:** `frame_ms > 0`; `superframe_ms` an integer multiple of `frame_ms`;
  `guard_us` expressed in µs and less than a frame.
- **Uniqueness:** `radio.id` unique; `service_flow.id` unique within a radio.
- **Referential integrity:** every id in a BS's `cpes[]` names an existing `cpe` radio whose
  `stack` is 802.22.
- **Conditional requirements:** `sensing.threshold_dbm` present when `sensing.enabled`;
  `wsdb.geo` present when `wsdb.enabled`; `substrate` present for every 802.22 radio and
  any SDR-backed radio; `transport.host`+`port` present when `transport.type == tcp`.
- **Role coherence:** a `cpe` may reference exactly one serving BS (`serving_bs`), which
  must exist and be a `bs`.

### 5.3 Why one contract, not two

The whole point of the netdev seam is that the layer above doesn't branch per stack. If
config branched per stack, that abstraction would leak. One contract with stack-tagged
entries keeps Meneldor, the apply-daemon, and mesh/routing stack-agnostic — they iterate
`radios[]` and dispatch on `stack`, exactly as `radioctl` already dispatches on `backend`.

---

## 6. Build & isolation axes

Three orthogonal axes, each isolated in the layout (`thorondor/gwaihir/...`):

- **Stack:** 802.11 (inherited) vs 802.22 (custom). Never mixed in one file.
- **Substrate/transceiver family:** AD936x · LMS7002M · LMS6002D · discrete — gateware forks.
- **Host arch:** x86_64 (bring-up) · arm64 (embedded SDR hosts) — module build forks.

Every file carries the notation header so CI can route builds per (stack, substrate, arch).

---

## 7. Open design decisions (tracked, not yet decided)

1. **PHY placement:** FPGA gateware vs userspace soft-PHY vs split — pending the SDR
   substrate decision (the matrix supports all; the choice sets where the OFDMA/sensing work
   lands and how tight the Gwaihir↔PHY interface must be).
2. **MAC policy split:** how much of grant/service-flow policy lives in the kernel module vs
   a userspace policy daemon (timing in kernel is settled; policy placement is not).
3. **Westron serialization ergonomics:** JSON is canonical (portable across Python/PowerShell/
   `jq`); a TOML authoring front-end that serializes to the same model is a likely convenience
   layer.
4. **Sensing↔WSDB authority:** when local sensing and the white-space DB disagree, which
   wins, and how that decision is expressed in config vs enforced in the sensing daemon.

These do not block the config contract — the contract is written to express all of them.
