# Hardware BOM — modding-friendly Wi-Fi platforms for the radioctl/radio-inject stack

Canonical hardware matrix for the project. Tracks the good/better/best options per
category with the one caveat that actually governs the choice for this stack:
**MAC-timing control**. Revise as hardware and OpenWrt support evolve.

---

## BLUF

- **Top pick — OpenWrt One** (MediaTek MT7981B + MT7976, Wi-Fi 6). Official OpenWrt
  reference board, effectively unbrickable dual-boot, ~$89. Drops straight into
  `radioctl` as a `wifi-mac` node and runs `radio-inject` today.
- **Runner-up — GL.iNet Flint 2 (GL-MT6000)** (MT7981B + MT7976, Wi-Fi 6, dual 2.5GbE,
  1 GB RAM / 8 GB eMMC, ~$150). Community default; more CPU/RAM headroom for daemons.

**The governing caveat:** MediaTek/`mt76` is the modern successor to ath9k as the
open, community-maintained OpenWrt platform, and monitor mode + injection work on it.
But `mt76` uses non-free firmware and offloads sequencing/aggregation/scheduling into
firmware, so it does **not** restore ath9k's register-level MAC-timing control — and
newer (Wi-Fi 6E/7) offloads *more*, not less. Modern APs are excellent **surrogate-PHY
nodes** (validate L2 logic, run the injector, serve RX-diversity). For deterministic
**slot timing**, stay on ath9k or push that determinism up to the netdev/SDR path.

Rule of thumb: **avoid Broadcom** for anything Wi-Fi under OpenWrt (weak/absent driver
support). Prefer MediaTek Filogic; Qualcomm ipq806x (e.g. R7800) is well-supported but
its ath10k radio is closed-firmware like the rest.

---

## Category 1 — Flash-and-go OpenWrt AP (turnkey `wifi-overlay` / `wifi-mac` node)

| Tier | Device | SoC / radio | MAC-control caveat | Notes |
|---|---|---|---|---|
| Good | Linksys E8450 / Belkin RT3200 | MT7622 + MT7915 (Wi-Fi 6) | Firmware-offloaded (mt76); injection OK | Budget classic; install needs one-time UBI-layout conversion |
| Better | GL.iNet Flint 2 (GL-MT6000) | MT7981B + MT7976 (Wi-Fi 6) | Firmware-offloaded (mt76); injection OK | Best all-rounder; ships OpenWrt-based; headroom for daemons |
| Best | OpenWrt One | MT7981B + MT7976 (Wi-Fi 6) | Firmware-offloaded (mt76); injection OK | Reference board; unbrickable; mainline-first support |

## Category 2 — DIY research board (expandable testbed node)

| Tier | Device | SoC / radio | MAC-control caveat | Notes |
|---|---|---|---|---|
| Good | Banana Pi BPI-R3 | MT7986 (Filogic 830) + MT7975/76 (Wi-Fi 6) | Firmware-offloaded (mt76) | 2× SFP+, M.2/mPCIe; strong community |
| Better | Banana Pi BPI-R4 | MT7988A (Filogic 880) + optional MT7996 (Wi-Fi 7) | Firmware-offloaded; **worse** control (Wi-Fi 7) | 2× 10G SFP+, PCIe/M.2; more lanes for multiple radios |
| Best | (see Category 3 — x86) | — | — | A board can't match a real host for slot-timing work |

## Category 3 — Max MAC control (x86 host + card — the "build" path)

Runs `radioctl` + `radio-inject` directly; a real CPU removes the MIPS jitter tax.

| Tier | Radio card | Bus | MAC-control caveat | Notes |
|---|---|---|---|---|
| Good | MediaTek MT7612 (mt76) | miniPCIe | Firmware-offloaded; injection OK | Cheap modern-ish node |
| Better | MediaTek MT7915 / MT7916 (mt76) | M.2 | Firmware-offloaded; injection kernel-verified | Best *modern-band* control you'll get |
| Best (timing) | Atheros AR9280 / AR9380 (ath9k) | PCIe / miniPCIe | **Full soft-MAC register access** | For a scheduled MAC where slot boundaries are the acceptance criterion, ath9k still wins despite being 802.11n |

## Category 4 — USB injection / RX-diversity nodes (the multi-antenna fleet idea)

| Tier | Device | Chipset / driver | MAC-control caveat | Notes |
|---|---|---|---|---|
| Good | Alfa AWUS036ACM | MT7612U (mt76) | Firmware-offloaded; injection OK | Dual-band; solid all-round |
| Better | Alfa AWUS036AXML | MT7921AU (mt76) | Firmware-offloaded; **active-monitor** has broken the mt7921u driver — prefer capture-only | Adds 6 GHz (Wi-Fi 6E) |
| Best (injection) | Alfa AWUS036NHA | AR9271 (ath9k_htc) | USB MAC blob; less timing control than PCIe ath9k, but bulletproof injection | Old but rock-solid; TL-WN722N **v1** is the same chipset |

---

## How to choose for this project

- **First modern node:** OpenWrt One → `radioctl` `wifi-mac` backend, runs `radio-inject`.
- **Deterministic slot-timing validation:** x86 + ath9k (AR9280/AR9380).
- **RX diversity substrate (`fleet-capture`):** several Alfa AWUS036ACM across one host.
- **Surrogate-PHY vs real MAC control:** let mt76 nodes carry surrogate-PHY + diversity;
  reserve ath9k / the SDR path for anything that must own MAC timing.

## Pre-purchase checklist

1. Confirm the exact **hardware revision** against the OpenWrt Table of Hardware —
   support is per-revision, and lookalike model numbers differ.
2. Verify **"supported" or better** status on ToH, not just forum claims.
3. Floor for longevity: **≥16 MB flash / ≥128 MB RAM** (all Category 1–2 picks clear it).
4. For USB adapters, **verify the chipset**, not the model name (e.g. WN722N v1 = Atheros,
   v2/v3 = Realtek — not interchangeable).
5. Prices above are ballpark — **verify current** before purchase.

---

_Last updated: this session. Canonical source for the hardware matrix; the acceptance
log links here rather than duplicating it._
