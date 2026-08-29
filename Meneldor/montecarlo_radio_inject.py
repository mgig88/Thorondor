#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# montecarlo_radio_inject.py — property-based Monte Carlo tests for radio-inject.
#
# Loads the radio-inject module directly and hammers its pure functions
# (build_frame / parse_frame / pcap_write / pcap_read) with thousands of
# randomized inputs across best-fit usage scenarios. Every scenario asserts an
# invariant that MUST hold for the code to be defect-free. Exits non-zero on any
# failure. Deterministic (seeded) so a failure is reproducible.
#
#   python3 montecarlo_radio_inject.py [iterations] [seed]
# -----------------------------------------------------------------------------
import importlib.util
import os
import random
import sys
import tempfile

RI_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "radio-inject")

def load_module(path):
    from importlib.machinery import SourceFileLoader
    loader = SourceFileLoader("radio_inject", path)
    spec = importlib.util.spec_from_loader("radio_inject", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod

ri = load_module(RI_PATH)

ITERS = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
SEED = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0xC0FFEE
rng = random.Random(SEED)

# ---- counters ----
stats = {}       # scenario -> [runs, fails]
failures = []    # (scenario, detail)

def record(scn, ok, detail=""):
    s = stats.setdefault(scn, [0, 0])
    s[0] += 1
    if not ok:
        s[1] += 1
        failures.append((scn, detail))

# ---- generators ----
def rand_mac():
    return ":".join("%02x" % rng.randint(0, 255) for _ in range(6))

def rand_body(max_len=2304):
    n = rng.randint(0, max_len)
    return bytes(rng.randint(0, 255) for _ in range(n))

def rand_txflags():
    return rng.randint(0, 0xFFFF)

# =============================================================================
# S1 — frame build/parse round-trip (the core injection path)
# =============================================================================
def s1_roundtrip():
    src, dst, bssid = rand_mac(), rng.choice([ri.BROADCAST, rand_mac()]), rand_mac()
    seq = rng.randint(0, 70000)                    # deliberately > 12 bits sometimes
    body = rand_body()
    txf = rand_txflags()
    frame = ri.build_frame(src, dst, bssid, seq, body, txf)
    p = ri.parse_frame(frame)
    checks = {
        "body": p["body"] == body,
        "src": p["src"] == src.lower(),
        "dst": p["dst"] == dst.lower(),
        "bssid": p["bssid"] == bssid.lower(),
        "seq": p["seq"] == (seq & 0x0FFF),
        "type_data": p["fc_type"] == 2 and p["fc_subtype"] == 0,
        "rtlen": p["rtlen"] == 10,
        "txflags": p["txflags"] == (txf & 0xFFFF),
        "present": bool(p["present"] & ri.RT_PRESENT_TX_FLAGS),
        "len": len(frame) == 34 + len(body),       # 10 radiotap + 24 dot11 + body
    }
    ok = all(checks.values())
    record("S1 build/parse round-trip", ok,
           "" if ok else "src=%s dst=%s seq=%d blen=%d failed=%s"
           % (src, dst, seq, len(body), [k for k, v in checks.items() if not v]))

# =============================================================================
# S2 — overlay magic prefix (RX filter semantics used by cmd_rx)
# =============================================================================
def s2_magic():
    magic = bytes(rng.randint(0, 255) for _ in range(rng.randint(1, 8)))
    body = rand_body(256)
    tagged = magic + body
    frame = ri.build_frame(rand_mac(), ri.BROADCAST, rand_mac(), rng.randint(0, 4095),
                           tagged, ri.TX_FLAGS["noack"] | ri.TX_FLAGS["noseq"])
    p = ri.parse_frame(frame)
    # cmd_rx keeps a frame iff body.startswith(magic); a wrong magic must be rejected
    wrong = bytes([(magic[0] ^ 0xFF)]) + magic[1:]
    ok = p["body"].startswith(magic) and not p["body"].startswith(wrong)
    record("S2 overlay magic filter", ok,
           "" if ok else "magic=%s bodystart=%s" % (magic.hex(), p["body"][:8].hex()))

# =============================================================================
# S3 — pcap write/read round-trip (DLT 127 archive path)
# =============================================================================
def s3_pcap():
    n = rng.randint(1, 12)
    built = []
    for k in range(n):
        f = ri.build_frame(rand_mac(), ri.BROADCAST, rand_mac(), k, rand_body(300),
                           ri.TX_FLAGS["noack"] | ri.TX_FLAGS["noseq"])
        built.append((rng.random() * 1e6, f))
    fd, path = tempfile.mkstemp(suffix=".pcap"); os.close(fd)
    try:
        ri.pcap_write(path, built)
        back = ri.pcap_read(path)
        ok = len(back) == n and all(back[k][1] == built[k][1] for k in range(n))
        # bodies must also survive re-parse
        if ok:
            ok = all(ri.parse_frame(back[k][1])["body"] == ri.parse_frame(built[k][1])["body"]
                     for k in range(n))
        record("S3 pcap round-trip", ok,
               "" if ok else "n=%d got=%d" % (n, len(back)))
    finally:
        os.remove(path)

# =============================================================================
# S4 — sequence train (mirrors cmd_tx --count/--seq loop)
# =============================================================================
def s4_seq_train():
    base = rng.randint(0, 4095)
    count = rng.randint(1, 64)
    body = rand_body(64)
    ok = True
    for i in range(count):
        seq = (base + i) & 0x0FFF
        p = ri.parse_frame(ri.build_frame(rand_mac(), ri.BROADCAST, rand_mac(), seq, body,
                                          ri.TX_FLAGS["noack"] | ri.TX_FLAGS["noseq"]))
        if p["seq"] != seq:
            ok = False
            break
    record("S4 sequence train", ok, "" if ok else "base=%d count=%d" % (base, count))

# =============================================================================
# S5 — strip-fcs behaviour (rx/pcap-dump option)
# =============================================================================
def s5_strip_fcs():
    body = rand_body(300)
    frame = ri.build_frame(rand_mac(), ri.BROADCAST, rand_mac(), rng.randint(0, 4095),
                           body, ri.TX_FLAGS["noack"])
    full = ri.parse_frame(frame, strip_fcs=False)["body"]
    stripped = ri.parse_frame(frame, strip_fcs=True)["body"]
    if len(body) >= 4:
        ok = full == body and stripped == body[:-4]
    else:
        ok = full == body and stripped == body        # <4 bytes: nothing to strip
    record("S5 strip-fcs", ok,
           "" if ok else "blen=%d full=%d strip=%d" % (len(body), len(full), len(stripped)))

# =============================================================================
# S6 — helper functions (mac round-trip, txflags naming, hexdump, radiotap)
# =============================================================================
def s6_helpers():
    m = rand_mac()
    mac_ok = ri.bytes2mac(ri.mac2bytes(m)) == m.lower()
    # txflags_names: every named flag appears iff its bit is set
    txf = rand_txflags()
    names = ri.txflags_names(txf)
    name_ok = all((n in names) == bool(txf & v) for n, v in ri.TX_FLAGS.items())
    # radiotap header is always exactly 10 bytes and advertises TX_FLAGS
    rt = ri.build_radiotap(txf & 0xFFFF)
    rt_ok = len(rt) == 10
    # hexdump never raises and is empty-marked only for empty input
    body = rand_body(128)
    hd = ri.hexdump(body)
    hd_ok = (("(empty)" in hd) == (len(body) == 0)) and isinstance(hd, str)
    ok = mac_ok and name_ok and rt_ok and hd_ok
    record("S6 helpers", ok,
           "" if ok else "mac=%s names=%s rt=%s hd=%s" % (mac_ok, name_ok, rt_ok, hd_ok))

# =============================================================================
# Deterministic edge cases (run once each, not randomized)
# =============================================================================
def edge_cases():
    E = ri.TX_FLAGS["noack"] | ri.TX_FLAGS["noseq"]
    cases = [
        ("empty body", b""),
        ("1 byte", b"\x00"),
        ("exactly 4 (fcs boundary)", b"\xde\xad\xbe\xef"),
        ("max msdu 2304", bytes(2304)),
        ("high bytes", bytes([0xFF] * 100)),
    ]
    for name, body in cases:
        p = ri.parse_frame(ri.build_frame("02:00:00:00:00:01", ri.BROADCAST,
                                          "02:00:00:00:00:ff", 0, body, E))
        record("EDGE %s" % name, p["body"] == body and p["dst"] == ri.BROADCAST)
    # seq wrap boundaries
    for seq, expect in [(0, 0), (4095, 4095), (4096, 0), (5000, 5000 & 0xFFF), (65535, 4095)]:
        p = ri.parse_frame(ri.build_frame("02:00:00:00:00:01", ri.BROADCAST,
                                          "02:00:00:00:00:ff", seq, b"x", E))
        record("EDGE seq wrap %d" % seq, p["seq"] == expect,
               "" if p["seq"] == expect else "got %d want %d" % (p["seq"], expect))
    # all single-flag values
    for name, val in ri.TX_FLAGS.items():
        p = ri.parse_frame(ri.build_frame("02:00:00:00:00:01", ri.BROADCAST,
                                          "02:00:00:00:00:ff", 0, b"x", val))
        record("EDGE txflag %s" % name, p["txflags"] == val)

# ---- run ----
def main():
    print("radio-inject Monte Carlo  module=%s  iters=%d  seed=0x%X"
          % (RI_PATH, ITERS, SEED))
    scenarios = [s1_roundtrip, s2_magic, s3_pcap, s4_seq_train, s5_strip_fcs, s6_helpers]
    for _ in range(ITERS):
        rng.choice(scenarios)()
    edge_cases()

    print("\n%-30s %10s %8s" % ("scenario", "runs", "fails"))
    print("-" * 50)
    total_runs = total_fails = 0
    for scn in sorted(stats):
        runs, fails = stats[scn]
        total_runs += runs; total_fails += fails
        print("%-30s %10d %8d" % (scn, runs, fails))
    print("-" * 50)
    print("%-30s %10d %8d" % ("TOTAL", total_runs, total_fails))

    if failures:
        print("\nFAILURES (first 10):")
        for scn, detail in failures[:10]:
            print("  [%s] %s" % (scn, detail))
        print("\nRESULT: FAIL (%d defect observations)" % total_fails)
        return 1
    print("\nRESULT: PASS — no defects across %d randomized assertions" % total_runs)
    return 0

if __name__ == "__main__":
    sys.exit(main())
