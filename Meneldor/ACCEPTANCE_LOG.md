# radio-inject — Acceptance & Session Log

Component: `radio-inject` (radioctl SEAM #1) · Version 0.1.0 · Status: **ACCEPTED (bench, hardware-free)**
Document type: critical-acceptance tool log. Structure: **BLUF → Actions Taken → Q&A Ledger → Reference → Acceptance Criteria → Live Bring-up → Testbed Preview**.

---

## BLUF

`radio-inject` is delivered and passes its full hardware-free acceptance self-check
(**34/34 checks PASS, exit 0**). It is the concrete implementation of SEAM #1 — the
raw 802.11 injector the `wifi-overlay` (ath10k/LiteBeam) and `wifi-mac` (ath9k)
backends call to put your L2.5 overlay PDUs on the air.

Design decisions that matter for acceptance:
- **Stdlib-only (no scapy).** Frame construction is hand-built from `struct`, so
  every byte on the wire is auditable and the supply chain is minimal — appropriate
  for a critical tool.
- **Broadcast + NOACK by default.** Broadcast receiver address means 802.11 hardware
  does not auto-ACK, so the NIC's lower MAC does not impose its own reliability layer
  — your L2 ARQ/HARQ owns reliability. Radiotap `TX_FLAGS` carries `NOACK` (no
  ACK/retry) and `NOSEQ` (driver does not overwrite the sequence number, so **your L2
  owns ordering**).
- **Verifiable with no radio.** `selftest`, `--dry-run`, `--pcap`, and `pcap-dump`
  validate the full build/parse path offline (also the only paths available to a
  Windows operator; live tx/rx require Linux `AF_PACKET`).

What is **not** in scope for this component (by design): EDCA/backoff minimisation
(that is ath9k debugfs tuning on the `wifi-mac` side), and the SDR PHY (SEAM #2).
**Compliance dependency:** live TX prints a banner reminding that TVWS emission is
geolocation/WSDB-gated (SEAM #3) before any antenna port.

Next deliverable (flagged by you, not yet built): a **two-profile testbed** — one
instance for me to lab ideas, one for you — with an open scoping question at the end
of this document.

---

## Actions Taken (this session)

Chronological record of concrete actions and their verified results.

1. **Built `radio-inject`** (`/mnt/user-data/outputs/radio-inject`) — single-file
   Python 3, stdlib only. Subcommands: `tx`, `rx`, `selftest`, `pcap-dump`.
   - Hand-built 10-byte radiotap header carrying only the `TX_FLAGS` field.
   - Minimal 24-byte 802.11 DATA frame (toDS=fromDS=0; addr1=DA, addr2=SA, addr3=BSSID).
   - AF_PACKET `SOCK_RAW` for live tx/rx on a monitor interface; pure `struct` for
     build/parse so it runs with no hardware.
   - pcap writer/reader at `DLT_IEEE802_11_RADIOTAP` (127) for Wireshark inspection.

2. **Ran the acceptance self-check** — `python3 radio-inject selftest`.
   - Result: **34/34 checks PASS**, exit code **0**, `SELFTEST PASSED`.
   - Coverage: body preservation across 4 payloads (empty → 64 bytes), broadcast DA,
     src/seq preservation, DATA-frame type, `NOACK` set, `NOSEQ` set, radiotap len==10,
     and a 3-frame pcap round-trip (count + body integrity).

3. **Verified the exact bytes on the wire** — `tx --dry-run --verbose`.
   - A broadcast frame with payload `08004500DEADBEEF` renders as a 42-byte frame;
     radiotap `present=0x00008000` (TX_FLAGS), `TX_FLAGS=0x0018` (NOACK|NOSEQ),
     FC=`08 00` (DATA/type 2), addr1=`ff:ff:ff:ff:ff:ff`. Anatomy table below.

4. **Verified the pcap round-trip and overlay-magic filter** — `tx --pcap` then
   `pcap-dump`. 3 frames written with seq 100→102 and a `RADO` (`5241444F`) magic
   prefix; read back byte-identical.

5. **Confirmed platform behaviour** — `AF_PACKET` present ⇒ live tx/rx enabled on the
   Linux host; on a platform without it the tool fails closed with a clear message
   pointing at `selftest`/`pcap-dump`/the Linux radio host.

6. **Wired SEAM #1 into the project** — updated `README.md` to mark SEAM #1 as
   implemented and reference this log.

---

## Q&A Ledger

Every question you have asked in this workstream, with the answer of record.

**Q1 — "Are you familiar with OpenWrt?"**
A: Yes. Linux-based router OS: UCI config, LuCI, opkg/apk, fw4/nftables, DSA switch
config, WireGuard, 802.11s/batman-adv mesh, SQM/CAKE. Runs on consumer routers, x86,
SBCs. It is the right **host/control** layer for this project.

**Q2 — Custom OpenWrt build for testing custom protocols on non-WiFi / white-space
frequencies; GPS to be added later; deploy on radios including the Ubiquiti LiteBeam AC.**
A: Key constraints established:
- OpenWrt is Linux + networking userspace, **not a radio**. It spans your fleet only
  at the Linux/networking layer, never at the PHY.
- The **LiteBeam AC cannot reach TV white space** — it is a 5 GHz QCA9563 + ath10k
  device; the analog front end / PLL / antenna are built for ~5 GHz. No firmware
  change makes it lock at VHF/UHF.
- Your fleet is therefore **two disjoint PHY worlds**: WiFi-chipset radios (MAC/
  protocol experiments inside their native band) and SDRs (the actual white-space /
  arbitrary-waveform PHY).
- Build with **full buildroot**, not ImageBuilder (kernel/driver/regdb changes).
- Check for a **locked (signed) U-Boot** before standardising on LiteBeam hardware.
- **GPS is compliance, not just a feature**: TVWS requires geolocation → white-space
  DB query for permitted channels/power (FCC Part 15 Subpart H). Fine to defer for
  shielded bring-up; load-bearing before any real antenna.

**Q3 — "Continue with the PHY constraint and enable disparate L2 protocols like 802.22
over 5 GHz."**
A: This is **surrogate-PHY validation** — it validates your L2 *logic*, not RF behaviour.
- Ports cleanly: connection-oriented MAC state machine, superframe/frame scheduling,
  service-flow/QoS model, coexistence signalling.
- Does not port: the OFDMA PHY, spectrum sensing, 6/7/8 MHz channelisation, and the
  timing constants (802.22's ~100 km / 160 ms superframe geometry is absurd on a bench
  — parameterise every timing constant now).
- **Core mismatch:** a scheduled, grant-based 802.22-lineage MAC running on top of
  802.11's contention MAC (CSMA/CA, backoff, auto-ACK, retries), which actively fights
  you. Your stack becomes an upper-MAC/L2.5 overlay; the job is neutralising the
  hardware MAC beneath it.
- Techniques: send as **broadcast/multicast** (no auto-ACK), radiotap **NOACK**,
  minimise EDCA backoff. → This is exactly what `radio-inject` now implements.
- **ath9k ≫ ath10k** for this (open driver, tunable MAC/queues; the LiteBeam's ath10k
  lower-MAC is a closed blob). Consider WMP/MAClet to push a slot scheduler onto ath9k.
- Present the L2 upward as a **TUN/TAP netdev** — that netdev seam is also where the
  eventual SDR PHY plugs in interchangeably.

**Q4 — "Have more than one device/antenna at a time to harvest diversity?" + "Make one
customizable piece of software, CLI in PowerShell and bash, spanning least-constrained
overlay to fully customizable MAC/PHY."**
A: Yes on diversity — it buys **selection/spatial diversity** (independent RX chains,
same broadcast domain, different fading) and **broadcast-domain coverage** (separated
receivers hearing different subsets). Delivered `radioctl` (bash + PowerShell,
feature-parity) built on a HAL with four backends (`mock`, `wifi-overlay`, `wifi-mac`,
`sdr`), a fleet config, and `fleet-capture` for the diversity substrate. Combining
logic stays one layer up in your L2.

**Q5 — (Resend of Q4.)**
A: Confirmed already delivered; disambiguated next steps (netdev seam vs concrete
injector) rather than regenerating.

**Q6 — "Proceed with radio-inject. A testbed will follow (one version for you, one for
me). Critical acceptance tool — take your time, document all actions, my questions with
answers, and a BLUF at top."**
A: This deliverable — `radio-inject` + this acceptance log. Testbed scoped below.

---

## Reference — `radio-inject`

### Frame anatomy (verified, broadcast + NOACK+NOSEQ)

Example: `tx --hex 08004500DEADBEEF --broadcast` → 42-byte frame.

| Offset | Bytes | Field | Meaning |
|---|---|---|---|
| 0 | `00` | radiotap version | 0 |
| 1 | `00` | radiotap pad | — |
| 2–3 | `0a 00` | radiotap len | 10 bytes |
| 4–7 | `00 80 00 00` | present bitmap | `0x00008000` = TX_FLAGS present |
| 8–9 | `18 00` | TX_FLAGS | `0x0018` = NOACK (0x08) \| NOSEQ (0x10) |
| 10–11 | `08 00` | FC | type=2 (DATA), subtype=0, ver 0 |
| 12–13 | `00 00` | Duration | 0 |
| 14–19 | `ff ff ff ff ff ff` | addr1 / DA | broadcast → no auto-ACK |
| 20–25 | `02 00 00 00 00 01` | addr2 / SA | `--src` |
| 26–31 | `02 00 00 00 00 ff` | addr3 / BSSID | `--bssid` |
| 32–33 | `00 00` | Seq control | seq 0, frag 0 |
| 34+ | `08 00 45 00 de ad be ef` | body | your L2.5 PDU |

No FCS is appended — mac80211 computes it on injection.

### Subcommands

```
radio-inject tx  --iface mon0 --hex <HEX> [--broadcast] [--no-ack]
                 [--dst MAC] [--src MAC] [--bssid MAC] [--seq N]
                 [--overwrite-seq] [--magic HEX] [--count N] [--interval S]
                 [--pcap FILE] [--dry-run] [--verbose]
radio-inject rx  --iface mon0 [--count N] [--timeout S] [--magic HEX]
                 [--strip-fcs] [--pcap FILE] [--verbose]
radio-inject selftest                       # hardware-free acceptance check
radio-inject pcap-dump --pcap FILE [--strip-fcs] [--verbose]
```

Payload source is one of `--hex`, `--file`, `--stdin`. `--magic` prepends a hex tag to
the body so `rx`/`pcap-dump` can filter your overlay traffic from ambient WiFi.

### Flag semantics that carry protocol meaning

- **`--no-ack` / broadcast → NOACK.** Auto-on for broadcast. Suppresses the NIC's
  ACK-wait and hardware retries so your ARQ/HARQ is the *only* reliability layer.
- **`--overwrite-seq` clears NOSEQ.** Default keeps NOSEQ set so the driver preserves
  the sequence number you set with `--seq` — your L2 owns ordering. Only pass this if
  you deliberately want the hardware to assign sequence numbers.

### Platform matrix

| Path | Linux | Windows / other |
|---|---|---|
| `selftest`, `pcap-dump`, `tx --dry-run`, `tx --pcap` | ✅ | ✅ (offline frame validation) |
| `tx` (live), `rx` (live) | ✅ (root + monitor iface) | ❌ — fails closed with guidance; drive the Linux radio host over SSH |

### Compliance gate

Live `tx` prints a stderr banner: emission must be within authorized/confined spectrum,
and TVWS operation is geolocation/WSDB-gated (radioctl SEAM #3) before any antenna port.
The tool does not hard-block (shielded-lab use is the intended path) but the reminder is
always emitted on real transmit.

---

## Acceptance Criteria → Evidence

| # | Criterion | How verified | Result |
|---|---|---|---|
| A1 | Arbitrary payload survives build→parse byte-identical | selftest, 4 payloads (0–64 B) | PASS |
| A2 | Receiver address is broadcast (no auto-ACK) | selftest `dst is broadcast` | PASS |
| A3 | radiotap advertises NOACK | selftest `NOACK set` | PASS |
| A4 | Sequence not overwritten (L2 owns ordering) | selftest `NOSEQ set` + `seq preserved` | PASS |
| A5 | Frame is a DATA frame (type 2) | selftest `is DATA frame` | PASS |
| A6 | radiotap header well-formed (len 10) | selftest `radiotap len == 10` | PASS |
| A7 | pcap round-trips at DLT 127 | selftest pcap section + `pcap-dump` | PASS |
| A8 | Fails closed off-Linux with clear guidance | AF_PACKET guard | PASS (by inspection) |
| A9 | Overlay magic prefix filters RX | `--magic 5241444F` in pcap-dump | PASS |

Re-run acceptance any time: `python3 radio-inject selftest` (exit 0 = accepted).

---

## Live hardware bring-up (ath9k, when you have the radio)

`radioctl` drives steps 1–3; `radio-inject` is step 4.

1. Create a monitor vif and tune it (radioctl `wifi-mac` backend `up`):
   `iw dev wlan0 interface add mon0 type monitor; ip link set mon0 up; iw dev mon0 set freq 5180 HT20`
2. (ath9k) minimise backoff toward contention-free slotting via
   `/sys/kernel/debug/ieee80211/phyN/ath9k/` (CWmin/CWmax/AIFS).
3. Confirm reachability: `radio-inject rx --iface mon0 --magic 5241444F -v` on a peer.
4. Inject: `radio-inject tx --iface mon0 --hex <PDU> --broadcast --magic 5241444F -v`
   (add `--count`/`--interval` for a frame train; `--pcap` to archive what you sent).
Root (CAP_NET_RAW) required for live tx/rx.

---

## Testbed Preview (next deliverable — not yet built)

You flagged two profiles: **"one for you, one for me to lab out ideas."** My working
interpretation, to confirm:

- **Operator/lab profile (yours):** drives real or staged hardware — `radioctl` +
  `radio-inject` against ath9k/LiteBeam/SDR, with capture archiving and a scenario
  runner you edit.
- **Reference/CI profile (mine):** fully hardware-free — the `mock` backend plus
  `radio-inject` selftest/dry-run/pcap, wired as a repeatable acceptance harness that
  proves L2 behaviour and frame integrity on any box, so we can iterate on protocol
  logic without a radio in the loop.

Both would share one scenario format (frames/timing/expected-RX) so a scenario that
passes in the reference profile can be replayed on real hardware in the lab profile —
the same surrogate-first principle as the rest of the stack.

**Open scoping question (one, to start the testbed right):** at what layer should the
testbed drive traffic — **(a)** at `radio-inject`'s frame layer (hex PDUs in, captured
frames out; validates framing/timing/injection), or **(b)** one layer up at the
**TUN/TAP netdev** (IP/L2 payloads in, so your actual 802.22-derived MAC/ARQ runs
inside the loop)? (a) is buildable immediately on what exists; (b) needs the netdev
seam built first and exercises far more of your real stack.

---

## Hardware BOM

Canonical hardware matrix lives in **`HARDWARE_BOM.md`** (standalone, for GitHub
tracking) rather than being duplicated here. Summary:

- **Top two:** OpenWrt One (MT7981B, ~$89, unbrickable reference board) and GL.iNet
  Flint 2 (MT7981B, ~$150, more headroom). Both `mt76`, both run `radio-inject`.
- **Governing caveat, recorded per option in the BOM:** `mt76` restores ath9k's
  *openness* and injection but **not** its register-level MAC-timing control (firmware
  offload; Wi-Fi 6E/7 offloads more). Modern APs = surrogate-PHY + RX-diversity nodes;
  reserve **ath9k (x86 + AR9280/AR9380)** or the SDR path for deterministic slot timing.
- Categories covered: flash-and-go AP, DIY research board, x86+card (max control),
  USB injection/diversity nodes — each with good/better/best and the MAC-control note.

## Verification — Monte Carlo (this session)

Full detail in **`MONTECARLO_REPORT.md`**. Result: **20,765 randomized assertions, 0
defects** on every executable path.

| Component | Assertions | Fails | Notes |
|---|---:|---:|---|
| `radio-inject` (Python) | 20,015 | 0 | build/parse, magic filter, pcap, seq train, strip-fcs, edges |
| `radioctl.sh` (bash) | 750 | 0 | resolution precedence, freq gating, mock loopback, dispatch, fleet |
| `radioctl.ps1` (PowerShell) | — | — | not executed here (no `pwsh`); parity-verified (29/29 backend fns, identical command surface); Windows harness shipped |

One harness-only bug (module loader) was found and fixed; no defects in delivered code.
Reproduce: `python3 montecarlo_radio_inject.py` · `bash montecarlo_radioctl.sh` ·
`pwsh -File montecarlo_radioctl.ps1` (Windows).

## File manifest

| File | Role |
|---|---|
| `radio-inject` | SEAM #1 injector/receiver |
| `radioctl.sh` / `radioctl.ps1` | control-plane CLIs (bash / PowerShell) |
| `radios.conf` | fleet definition |
| `README.md` | project overview + seams |
| `HARDWARE_BOM.md` | hardware matrix / BOM (GitHub-tracked) |
| `montecarlo_radio_inject.py` | property-based tests for radio-inject |
| `montecarlo_radioctl.sh` / `.ps1` | scenario tests for the CLIs |
| `MONTECARLO_REPORT.md` | verification report |
| `ACCEPTANCE_LOG.md` | this document |
