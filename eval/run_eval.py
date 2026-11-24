#!/usr/bin/env python3
"""Replay recorded clips through a knock detector and score it.

    python3 eval/run_eval.py                              baseline on eval/data
    python3 eval/run_eval.py --sweep threshold=6,8,10,12,15
    python3 eval/run_eval.py --param threshold=8 -v       per-clip detail
    python3 eval/run_eval.py some/session/dir --json out.json

Replays each clip the way the app sees it: calibrate on the hands-off window,
feed the rest sample-by-sample, then split knocks into patterns with the same
quiet-gap rule as capture_pattern() and compare with patterns_match().

Metrics
  count_ok     rhythm clips where the detector found exactly the knocks performed
  capture_ok   rhythm clips where the pattern the app would capture has the right count
  TAR          genuine pairs (same rhythm, different clips) that would match -- i.e. the
               transfer would have worked. Capture failures count as non-matches.
  TAR x-sess   same, only pairs from different sessions (e.g. two different Macs)
  FAR          impostor pairs (different rhythms, same knock count) that would match
  FP/min       knocks detected per minute in negative clips (should be 0)
  false_pat    negative clips that produced a complete (>=3 knock) pattern
"""

import argparse
import itertools
import json
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import clips as C  # noqa: E402
import knockdrop as K  # noqa: E402


# ---------------------------------------------------------------- detectors
# A detector exposes calibrate_feed(v), finish_calibration(), feed(t, v) -> t | None,
# where v = (ax, ay, az, gx, gy, gz). Add new candidates here.

DETECTORS = {
    "baseline": lambda **kw: K.KnockDetector(**kw),
}

MATCHER_PARAMS = {"tolerance"}


# ---------------------------------------------------------------- replay

def samples(clip):
    """(t, 6-vector) pairs. Accel and gyro share hardware timestamps, so pair on t.
    (IMUKnocks._pairs() pairs by index, which misaligns when the two streams'
    first reads differ in length -- seen in real clips.)"""
    gyro = {round(g[0], 5): g for g in clip["gyro"]}
    out = []
    for a in clip["accel"]:
        g = gyro.get(round(a[0], 5))
        if g is not None:
            out.append((a[0], (a[1], a[2], a[3], g[1], g[2], g[3])))
    return out


def replay(clip, make_detector):
    det = make_detector()
    t_go = clip["t_go"]
    knocks = []
    calibrated = False
    for t, v in clip["_samples"]:
        if t < t_go:
            det.calibrate_feed(v)
            continue
        if not calibrated:
            det.finish_calibration()
            calibrated = True
        k = det.feed(t, v)
        if k is not None:
            knocks.append(k)
    return knocks


def capture(knocks):
    """Mirror capture_pattern(): split on > PATTERN_END_QUIET gaps, first group with a
    valid knock count is the pattern. The clip's end counts as quiet."""
    groups, cur = [], []
    for k in knocks:
        if cur and k - cur[-1] > K.PATTERN_END_QUIET:
            groups.append(cur)
            cur = []
        cur.append(k)
    if cur:
        groups.append(cur)
    for g in groups:
        if K.MIN_KNOCKS <= len(g) <= K.MAX_KNOCKS:
            return [k - g[0] for k in g], groups
    return None, groups


# ---------------------------------------------------------------- scoring

def pct(n, d):
    return f"{100 * n / d:5.1f}% ({n}/{d})" if d else "    -"


def evaluate(clips, detector, params):
    det_kw = {k: v for k, v in params.items() if k not in MATCHER_PARAMS}
    tolerance = params.get("tolerance", 0.12)
    make = lambda: DETECTORS[detector](**det_kw)

    rows = []
    for c in clips:
        knocks = replay(c, make)
        pattern, groups = capture(knocks)
        rows.append({"clip": c, "knocks": knocks, "pattern": pattern, "groups": groups})

    rhythm = [r for r in rows if r["clip"]["kind"] == "rhythm"]
    neg = [r for r in rows if r["clip"]["kind"] == "negative"]

    for r in rhythm:
        exp = r["clip"]["expected_knocks"]
        r["count_ok"] = len(r["knocks"]) == exp
        r["capture_ok"] = r["pattern"] is not None and len(r["pattern"]) == exp
        r["missed"] = max(0, exp - len(r["knocks"]))
        r["extra"] = max(0, len(r["knocks"]) - exp)

    genuine, impostor, gen_dist, imp_dist = [], [], [], []
    for a, b in itertools.combinations(rhythm, 2):
        ca, cb = a["clip"], b["clip"]
        same = ca["rhythm"] == cb["rhythm"]
        if not same and ca["expected_knocks"] != cb["expected_knocks"]:
            continue   # different counts can never match; not an informative impostor
        ok = (a["pattern"] is not None and b["pattern"] is not None
              and K.patterns_match(a["pattern"], b["pattern"], tolerance))
        cross = ca["session"] != cb["session"]
        (genuine if same else impostor).append((ok, cross))
        if a["capture_ok"] and b["capture_ok"]:
            d = K.pattern_distance(a["pattern"], b["pattern"])
            (gen_dist if same else imp_dist).append(d)

    minutes = sum(r["clip"]["t_end"] - r["clip"]["t_go"] for r in neg) / 60
    fp = sum(len(r["knocks"]) for r in neg)

    s = {
        "detector": detector, "params": params,
        "n_rhythm": len(rhythm), "n_negative": len(neg),
        "count_ok": sum(r["count_ok"] for r in rhythm),
        "capture_ok": sum(r["capture_ok"] for r in rhythm),
        "missed": sum(r["missed"] for r in rhythm),
        "extra": sum(r["extra"] for r in rhythm),
        "expected": sum(r["clip"]["expected_knocks"] for r in rhythm),
        "gen_pairs": len(genuine), "gen_match": sum(ok for ok, _ in genuine),
        "gen_x_pairs": sum(x for _, x in genuine), "gen_x_match": sum(ok and x for ok, x in genuine),
        "imp_pairs": len(impostor), "imp_match": sum(ok for ok, _ in impostor),
        "gen_dist": quantiles(gen_dist), "imp_dist": quantiles(imp_dist),
        "neg_minutes": minutes, "fp": fp, "fp_per_min": fp / minutes if minutes else None,
        "false_pattern": sum(r["pattern"] is not None for r in neg),
    }
    return s, rows


def quantiles(xs):
    if not xs:
        return None
    xs = sorted(xs)
    q = lambda p: xs[min(len(xs) - 1, int(p * len(xs)))]
    return {"n": len(xs), "min": xs[0], "p50": q(0.5), "p90": q(0.9), "max": xs[-1]}


# ---------------------------------------------------------------- reporting

def label(s):
    p = " ".join(f"{k}={v:g}" for k, v in s["params"].items())
    return f"{s['detector']}" + (f" {p}" if p else "")


def summary_table(results):
    hdr = (f"{'config':<28} {'count_ok':>15} {'capture_ok':>15} {'TAR':>15} {'TAR x-sess':>15} "
           f"{'FAR':>13} {'FP/min':>7} {'false_pat':>10}")
    print(hdr)
    print("-" * len(hdr))
    for s in results:
        fpm = f"{s['fp_per_min']:7.2f}" if s["fp_per_min"] is not None else "      -"
        print(f"{label(s):<28} {pct(s['count_ok'], s['n_rhythm']):>15} {pct(s['capture_ok'], s['n_rhythm']):>15} "
              f"{pct(s['gen_match'], s['gen_pairs']):>15} {pct(s['gen_x_match'], s['gen_x_pairs']):>15} "
              f"{pct(s['imp_match'], s['imp_pairs']):>13} {fpm} {s['false_pattern']:>4}/{s['n_negative']:<4}")


def breakdown(s, rows, verbose):
    rhythm = [r for r in rows if r["clip"]["kind"] == "rhythm"]
    neg = [r for r in rows if r["clip"]["kind"] == "negative"]
    print(f"\n== {label(s)}")
    if rhythm:
        print(f"knocks: {s['expected']} performed, {s['missed']} missed, {s['extra']} extra")
        for name, d in (("genuine", s["gen_dist"]), ("impostor", s["imp_dist"])):
            if d:
                print(f"{name} rhythm distance (n={d['n']}): min {d['min']:.3f}  p50 {d['p50']:.3f}  "
                      f"p90 {d['p90']:.3f}  max {d['max']:.3f}   (match if <= {s['params'].get('tolerance', 0.12)})")
        print("\nper rhythm / style            count_ok   miss  extra")
        keys = sorted({(r["clip"]["rhythm"], r["clip"].get("style", "normal")) for r in rhythm})
        for rh, st in keys:
            rs = [r for r in rhythm if r["clip"]["rhythm"] == rh and r["clip"].get("style", "normal") == st]
            print(f"  {rh + ' ' + st:<26} {sum(r['count_ok'] for r in rs):>3}/{len(rs):<4} "
                  f"{sum(r['missed'] for r in rs):>5} {sum(r['extra'] for r in rs):>6}")
    if neg:
        print("\nper negative scenario     knocks   min   FP/min  false_pat")
        for sc in sorted({r["clip"]["scenario"] for r in neg}):
            rs = [r for r in neg if r["clip"]["scenario"] == sc]
            m = sum(r["clip"]["t_end"] - r["clip"]["t_go"] for r in rs) / 60
            k = sum(len(r["knocks"]) for r in rs)
            print(f"  {sc:<22} {k:>7} {m:>6.2f} {k / m if m else 0:>8.1f} {sum(r['pattern'] is not None for r in rs):>6}/{len(rs)}")
    if verbose:
        print("\nper clip")
        for r in rows:
            c = r["clip"]
            exp = c["expected_knocks"]
            got = len(r["knocks"])
            flag = "ok " if got == exp else "BAD"
            rel = [round(k - c["t_go"], 2) for k in r["knocks"]]
            pat = (" gaps " + " ".join(f"{x:.2f}" for x in K.intervals(r["pattern"]))) if r["pattern"] else ""
            print(f"  {flag} {c['session'][:15]}/{c['id']:<34} exp {exp:>2} got {got:>2}  at {rel}{pat}")


def parse_params(items):
    out = {}
    for it in items or []:
        k, _, v = it.partition("=")
        out[k] = float(v)
    return out


def parse_sweep(items):
    axes = []
    for it in items or []:
        k, _, vs = it.partition("=")
        axes.append([(k, float(v)) for v in vs.split(",")])
    return [dict(combo) for combo in itertools.product(*axes)] if axes else [{}]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", default=[C.DATA_DIR], help="clip files or dirs (default eval/data)")
    ap.add_argument("--detector", default="baseline", choices=sorted(DETECTORS))
    ap.add_argument("--param", action="append", help="fixed param, e.g. threshold=8 or tolerance=0.15")
    ap.add_argument("--sweep", action="append", help="sweep a param, e.g. threshold=6,8,10 (repeatable)")
    ap.add_argument("-v", "--verbose", action="store_true", help="per-clip detail")
    ap.add_argument("--json", help="write full results to this file")
    args = ap.parse_args()

    paths = C.find_clips(args.paths)
    if not paths:
        sys.exit(f"no clips found in {', '.join(args.paths)} -- record some: python3 eval/record.py")
    clips = [C.load_clip(p) for p in paths]
    for c in clips:
        c["_samples"] = samples(c)
    sessions = sorted({c["session"] for c in clips})
    nr = sum(c["kind"] == "rhythm" for c in clips)
    print(f"{len(clips)} clips ({nr} rhythm, {len(clips) - nr} negative) from {len(sessions)} session(s)\n")

    base = parse_params(args.param)
    t0 = time.time()
    results = []
    for sweep in parse_sweep(args.sweep):
        params = dict(base, **sweep)
        results.append(evaluate(clips, args.detector, params))
    summary_table([s for s, _ in results])

    # detail for the default config if it was swept, else the single config
    pick = next(((s, r) for s, r in results if s["params"].get("threshold", 10.0) == 10.0), results[0])
    breakdown(*pick, verbose=args.verbose)
    print(f"\n({time.time() - t0:.1f}s)")

    if args.json:
        out = []
        for s, rows in results:
            out.append(dict(s, clips=[{
                "path": os.path.relpath(r["clip"]["path"]), "id": r["clip"]["id"], "kind": r["clip"]["kind"],
                "expected": r["clip"]["expected_knocks"],
                "knocks": [round(k - r["clip"]["t_go"], 4) for k in r["knocks"]],
                "pattern": r["pattern"],
            } for r in rows]))
        with open(args.json, "w") as f:
            json.dump(out, f, indent=1)
        print(f"wrote {args.json}")


if __name__ == "__main__":
    main()
