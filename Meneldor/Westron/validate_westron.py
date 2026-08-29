#!/usr/bin/env python3
# THORONDOR // component=westron-validator // stack=both // arch=any // status=draft
# -----------------------------------------------------------------------------
# validate_westron.py — semantic validator for the Westron config contract.
#
# Stdlib-only (json, argparse). Enforces BOTH the structural rules mirrored from
# westron.schema.json AND the cross-field / semantic rules a JSON Schema cannot
# express (referential integrity, superframe math, conditional requirements,
# TX-capability of the chosen SDR). Gate-able: exits non-zero on an invalid
# config, and --selftest runs a valid/invalid fixture battery for CI.
#
#   python3 validate_westron.py CONFIG.json     # validate one config
#   python3 validate_westron.py --selftest      # fixture battery (CI gate)
#
# Exit: 0 valid / all fixtures behaved; 1 config invalid; 2 usage; 3 selftest FAILED.
# -----------------------------------------------------------------------------
import argparse
import copy
import json
import sys

STACKS = {"802.11", "802.22"}
DEVICES = {"usrp", "lime", "bladerf", "hackrf", "pluto", "xtrx", "sidekiq",
           "rtlsdr", "airspy", "sdrplay", "kraken", "other"}
TX_CAPABLE = {"usrp", "lime", "bladerf", "hackrf", "pluto", "xtrx", "sidekiq", "other"}
ARCHS = {"x86_64", "arm64", "any"}
TRANSPORTS = {"local", "tcp"}
BW_11 = {20, 40, 80, 160}
CHAN_22 = {6, 7, 8}
DIRECTIONS = {"up", "down", "bidir"}
QOS = {"be", "nrtps", "rtps", "ertps", "ugs"}
ROLES = {"bs", "cpe"}

TV_MIN_MHZ, TV_MAX_MHZ = 54, 862          # TVWS envelope
WIFI_MIN_MHZ, WIFI_MAX_MHZ = 2400, 7125   # 2.4/5/6 GHz


def _is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _geo_errors(geo, where):
    e = []
    if not isinstance(geo, dict):
        return ["%s: geo must be an object" % where]
    for k in ("lat", "lon"):
        if k not in geo or not _is_num(geo[k]):
            e.append("%s: geo.%s missing or non-numeric" % (where, k))
    if "lat" in geo and _is_num(geo["lat"]) and not (-90 <= geo["lat"] <= 90):
        e.append("%s: geo.lat out of range" % where)
    if "lon" in geo and _is_num(geo["lon"]) and not (-180 <= geo["lon"] <= 180):
        e.append("%s: geo.lon out of range" % where)
    return e


def _substrate_errors(sub, where):
    e = []
    if not isinstance(sub, dict):
        return ["%s: substrate must be an object" % where]
    dev = sub.get("device")
    if dev not in DEVICES:
        e.append("%s: substrate.device %r not in %s" % (where, dev, sorted(DEVICES)))
    if "arch" in sub and sub["arch"] not in ARCHS:
        e.append("%s: substrate.arch %r invalid" % (where, sub["arch"]))
    tr = sub.get("transport")
    if not isinstance(tr, dict):
        e.append("%s: substrate.transport missing" % where)
    else:
        t = tr.get("type")
        if t not in TRANSPORTS:
            e.append("%s: transport.type %r invalid" % (where, t))
        if t == "tcp":
            if not tr.get("host"):
                e.append("%s: transport.type=tcp requires host" % where)
            p = tr.get("port")
            if not (isinstance(p, int) and 1 <= p <= 65535):
                e.append("%s: transport.type=tcp requires valid port" % where)
    return e


def _radio_11_errors(r, w):
    e = []
    if not r.get("iface"):
        e.append("%s: 802.11 radio requires iface" % w)
    rf = r.get("rf")
    if not isinstance(rf, dict):
        e.append("%s: 802.11 radio requires rf" % w)
    else:
        f = rf.get("freq_mhz")
        if not _is_num(f):
            e.append("%s: rf.freq_mhz missing/non-numeric" % w)
        elif not (WIFI_MIN_MHZ <= f <= WIFI_MAX_MHZ):
            e.append("%s: rf.freq_mhz %s outside Wi-Fi envelope %d-%d"
                     % (w, f, WIFI_MIN_MHZ, WIFI_MAX_MHZ))
        if rf.get("bw_mhz") not in BW_11:
            e.append("%s: rf.bw_mhz %r not in %s" % (w, rf.get("bw_mhz"), sorted(BW_11)))
    mac = r.get("mac", {})
    if isinstance(mac, dict) and "mode" in mac and mac["mode"] not in {"scheduled", "contention", "none"}:
        e.append("%s: mac.mode %r invalid" % (w, mac["mode"]))
    return e


def _radio_22_errors(r, w):
    e = []
    if r.get("role") not in ROLES:
        e.append("%s: 802.22 radio requires role in %s" % (w, sorted(ROLES)))
    # substrate required + must be TX-capable
    sub = r.get("substrate")
    if sub is None:
        e.append("%s: 802.22 radio requires substrate" % w)
    else:
        e += _substrate_errors(sub, w)
        if isinstance(sub, dict) and sub.get("device") in DEVICES and sub.get("device") not in TX_CAPABLE:
            e.append("%s: substrate.device %r is RX-only; cannot serve as 802.22 %s"
                     % (w, sub.get("device"), r.get("role")))
    # rf
    rf = r.get("rf")
    if not isinstance(rf, dict):
        e.append("%s: 802.22 radio requires rf" % w)
    else:
        c = rf.get("center_mhz")
        if not _is_num(c):
            e.append("%s: rf.center_mhz missing/non-numeric" % w)
        elif not (TV_MIN_MHZ <= c <= TV_MAX_MHZ):
            e.append("%s: rf.center_mhz %s outside TVWS envelope %d-%d"
                     % (w, c, TV_MIN_MHZ, TV_MAX_MHZ))
        if rf.get("channel_bw_mhz") not in CHAN_22:
            e.append("%s: rf.channel_bw_mhz %r not in %s" % (w, rf.get("channel_bw_mhz"), sorted(CHAN_22)))
        if not _is_num(rf.get("tx_power_dbm")):
            e.append("%s: rf.tx_power_dbm missing/non-numeric" % w)
    # superframe math
    sf = r.get("superframe")
    if not isinstance(sf, dict):
        e.append("%s: 802.22 radio requires superframe" % w)
    else:
        fm, sm, gu = sf.get("frame_ms"), sf.get("superframe_ms"), sf.get("guard_us")
        if not (_is_num(fm) and fm > 0):
            e.append("%s: superframe.frame_ms must be > 0" % w)
        if not (_is_num(sm) and sm > 0):
            e.append("%s: superframe.superframe_ms must be > 0" % w)
        if _is_num(fm) and _is_num(sm) and fm > 0 and abs((sm / fm) - round(sm / fm)) > 1e-9:
            e.append("%s: superframe_ms (%s) must be an integer multiple of frame_ms (%s)" % (w, sm, fm))
        if not (_is_num(gu) and gu > 0):
            e.append("%s: superframe.guard_us must be > 0" % w)
        elif _is_num(fm) and gu >= fm * 1000:
            e.append("%s: guard_us (%s) must be less than a frame (%s ms)" % (w, gu, fm))
    # service flows
    flows = r.get("service_flows", [])
    if flows and not isinstance(flows, list):
        e.append("%s: service_flows must be a list" % w)
    else:
        seen = set()
        for i, f in enumerate(flows or []):
            fw = "%s.service_flows[%d]" % (w, i)
            if not isinstance(f, dict):
                e.append("%s: not an object" % fw); continue
            fid = f.get("id")
            if not fid:
                e.append("%s: missing id" % fw)
            elif fid in seen:
                e.append("%s: duplicate service_flow id %r" % (fw, fid))
            else:
                seen.add(fid)
            if f.get("direction") not in DIRECTIONS:
                e.append("%s: direction %r invalid" % (fw, f.get("direction")))
            if f.get("qos") not in QOS:
                e.append("%s: qos %r invalid" % (fw, f.get("qos")))
            if "rate_kbps" in f and not (_is_num(f["rate_kbps"]) and f["rate_kbps"] >= 0):
                e.append("%s: rate_kbps must be >= 0" % fw)
    # sensing conditional
    sen = r.get("sensing")
    if isinstance(sen, dict) and sen.get("enabled"):
        if not _is_num(sen.get("threshold_dbm")):
            e.append("%s: sensing.enabled requires threshold_dbm" % w)
        if not (_is_num(sen.get("quiet_period_ms")) and sen["quiet_period_ms"] > 0):
            e.append("%s: sensing.enabled requires quiet_period_ms > 0" % w)
    # wsdb conditional
    wsdb = r.get("wsdb")
    if isinstance(wsdb, dict) and wsdb.get("enabled"):
        if not wsdb.get("db_url"):
            e.append("%s: wsdb.enabled requires db_url" % w)
        if "geo" not in wsdb:
            e.append("%s: wsdb.enabled requires geo" % w)
        else:
            e += _geo_errors(wsdb["geo"], w + ".wsdb")
    return e


def validate(cfg):
    """Return a list of human-readable error strings; empty list == valid."""
    e = []
    if not isinstance(cfg, dict):
        return ["top level must be an object"]
    if cfg.get("version") != 1:
        e.append("version must be integer 1")
    if not cfg.get("name"):
        e.append("name is required")
    if "geo" in cfg:
        e += _geo_errors(cfg["geo"], "deployment")
    radios = cfg.get("radios")
    if not isinstance(radios, list) or not radios:
        e.append("radios must be a non-empty array")
        return e

    ids = {}
    for i, r in enumerate(radios):
        w = "radio[%d]" % i
        if not isinstance(r, dict):
            e.append("%s: not an object" % w); continue
        rid = r.get("id")
        w = "radio[%s]" % (rid or i)
        if not rid:
            e.append("%s: missing id" % w)
        elif rid in ids:
            e.append("%s: duplicate radio id %r" % (w, rid))
        else:
            ids[rid] = r
        stack = r.get("stack")
        if stack not in STACKS:
            e.append("%s: stack %r not in %s" % (w, stack, sorted(STACKS)))
            continue
        if "substrate" in r and stack == "802.11":
            e += _substrate_errors(r["substrate"], w)
        if stack == "802.11":
            e += _radio_11_errors(r, w)
        else:
            e += _radio_22_errors(r, w)

    # referential integrity (second pass, once ids are known)
    for rid, r in ids.items():
        if r.get("stack") != "802.22":
            continue
        w = "radio[%s]" % rid
        if r.get("role") == "bs":
            for cid in r.get("cpes", []) or []:
                tgt = ids.get(cid)
                if tgt is None:
                    e.append("%s: cpes references unknown radio %r" % (w, cid))
                elif not (tgt.get("stack") == "802.22" and tgt.get("role") == "cpe"):
                    e.append("%s: cpes %r is not an 802.22 cpe" % (w, cid))
        if r.get("role") == "cpe" and "serving_bs" in r:
            tgt = ids.get(r["serving_bs"])
            if tgt is None:
                e.append("%s: serving_bs references unknown radio %r" % (w, r["serving_bs"]))
            elif not (tgt.get("stack") == "802.22" and tgt.get("role") == "bs"):
                e.append("%s: serving_bs %r is not an 802.22 bs" % (w, r["serving_bs"]))
    return e


# ---- selftest fixtures ------------------------------------------------------
def _good_config():
    return {
        "version": 1, "name": "selftest",
        "radios": [
            {"id": "w1", "stack": "802.11", "netdev": "wlan0", "iface": "wlan0",
             "rf": {"freq_mhz": 5180, "bw_mhz": 20}, "mac": {"mode": "scheduled"}},
            {"id": "bs", "stack": "802.22", "role": "bs", "netdev": "gwa0",
             "substrate": {"device": "usrp", "arch": "x86_64", "transport": {"type": "local"}},
             "rf": {"center_mhz": 605, "channel_bw_mhz": 6, "tx_power_dbm": 30},
             "superframe": {"frame_ms": 10, "superframe_ms": 160, "guard_us": 200},
             "service_flows": [{"id": "sf1", "direction": "down", "qos": "be", "rate_kbps": 100}],
             "sensing": {"enabled": True, "quiet_period_ms": 2, "threshold_dbm": -114},
             "wsdb": {"enabled": True, "db_url": "https://x/q", "geo": {"lat": 37.4, "lon": -78.6}},
             "cpes": ["cp"]},
            {"id": "cp", "stack": "802.22", "role": "cpe", "netdev": "gwa1", "serving_bs": "bs",
             "substrate": {"device": "pluto", "arch": "arm64",
                           "transport": {"type": "tcp", "host": "10.0.0.7", "port": 30000}},
             "rf": {"center_mhz": 605, "channel_bw_mhz": 6, "tx_power_dbm": 20},
             "superframe": {"frame_ms": 10, "superframe_ms": 160, "guard_us": 200},
             "sensing": {"enabled": False}, "wsdb": {"enabled": False}},
        ],
    }


def _selftest():
    fails = []

    def check(name, ok):
        print("  [%s] %s" % ("PASS" if ok else "FAIL", name))
        if not ok:
            fails.append(name)

    print("validate_westron selftest")
    print("-- valid reference config --")
    check("good config passes", validate(_good_config()) == [])

    print("-- each mutation must be rejected --")
    def mut(fn):
        c = copy.deepcopy(_good_config()); fn(c); return validate(c)

    cases = [
        ("bad version", lambda c: c.update(version=2)),
        ("missing name", lambda c: c.pop("name")),
        ("duplicate radio id", lambda c: c["radios"].append(dict(c["radios"][0]))),
        ("bad stack", lambda c: c["radios"][0].__setitem__("stack", "802.99")),
        ("wifi freq out of band", lambda c: c["radios"][0]["rf"].__setitem__("freq_mhz", 9000)),
        ("wifi bad bw", lambda c: c["radios"][0]["rf"].__setitem__("bw_mhz", 33)),
        ("22 center out of TVWS", lambda c: c["radios"][1]["rf"].__setitem__("center_mhz", 2400)),
        ("22 bad channel bw", lambda c: c["radios"][1]["rf"].__setitem__("channel_bw_mhz", 5)),
        ("superframe not multiple", lambda c: c["radios"][1]["superframe"].__setitem__("superframe_ms", 155)),
        ("guard >= frame", lambda c: c["radios"][1]["superframe"].__setitem__("guard_us", 20000)),
        ("RX-only device as BS", lambda c: c["radios"][1]["substrate"].__setitem__("device", "rtlsdr")),
        ("missing substrate on 22", lambda c: c["radios"][1].pop("substrate")),
        ("tcp without host", lambda c: c["radios"][2]["substrate"]["transport"].pop("host")),
        ("tcp bad port", lambda c: c["radios"][2]["substrate"]["transport"].__setitem__("port", 0)),
        ("sensing enabled w/o threshold", lambda c: c["radios"][1]["sensing"].pop("threshold_dbm")),
        ("wsdb enabled w/o geo", lambda c: c["radios"][1]["wsdb"].pop("geo")),
        ("bs references unknown cpe", lambda c: c["radios"][1].__setitem__("cpes", ["ghost"])),
        ("cpe serving unknown bs", lambda c: c["radios"][2].__setitem__("serving_bs", "ghost")),
        ("dup service flow id", lambda c: c["radios"][1]["service_flows"].append(
            dict(c["radios"][1]["service_flows"][0]))),
        ("bad qos", lambda c: c["radios"][1]["service_flows"][0].__setitem__("qos", "turbo")),
    ]
    for name, fn in cases:
        check("reject: " + name, len(mut(fn)) > 0)

    if fails:
        print("\nSELFTEST FAILED: %s" % ", ".join(fails))
        return 3
    print("\nSELFTEST PASSED (%d checks)" % (1 + len(cases)))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Validate a Westron config against the contract.")
    ap.add_argument("config", nargs="?", help="path to a Westron config JSON")
    ap.add_argument("--selftest", action="store_true", help="run the fixture battery (CI gate)")
    args = ap.parse_args(argv)

    if args.selftest:
        return _selftest()
    if not args.config:
        ap.error("provide a config path or --selftest")
    try:
        with open(args.config) as f:
            cfg = json.load(f)
    except (OSError, ValueError) as ex:
        print("error: cannot read/parse %s: %s" % (args.config, ex))
        return 1
    errors = validate(cfg)
    if errors:
        print("INVALID — %d error(s):" % len(errors))
        for er in errors:
            print("  - " + er)
        return 1
    print("VALID — %s conforms to the Westron contract" % args.config)
    return 0


if __name__ == "__main__":
    sys.exit(main())
