#!/usr/bin/env python3
"""Record labelled raw-sensor clips for the knock-detection eval.

    python3 eval/record.py                  full protocol (~12 min)
    python3 eval/record.py --quick          2 reps, fewer rhythms (~5 min)
    python3 eval/record.py --only idle,tri_a --reps 1

Walks you through rhythm clips (knock the rhythm shown) and negative clips
(typing, trackpad, handling... -- things that must NOT count as knocks).
Each clip: Enter -> short pause -> 1.2s hands-off calibration -> GO window.
Clips land in eval/data/<session>/ (see eval/clips.py for the format).

The detector's output is deliberately NOT shown while recording: only say a
clip is bad if *you* didn't do what was asked, so hard cases stay in the set.
"""

import argparse
import datetime
import os
import platform
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import clips as C  # noqa: E402

try:
    import termios
except ImportError:   # pragma: no cover
    termios = None


def sh(*cmd):
    try:
        return subprocess.check_output(cmd, text=True).strip()
    except Exception:
        return ""


class Quiet:
    """No echo / no line buffering while recording, so typing doesn't print and
    stray keys don't leak into the next prompt."""

    def __enter__(self):
        self.fd = sys.stdin.fileno() if sys.stdin.isatty() and termios else None
        if self.fd is not None:
            self.old = termios.tcgetattr(self.fd)
            new = termios.tcgetattr(self.fd)
            new[3] &= ~(termios.ECHO | termios.ICANON)
            termios.tcsetattr(self.fd, termios.TCSANOW, new)
        return self

    def __exit__(self, *exc):
        if self.fd is not None:
            termios.tcflush(self.fd, termios.TCIFLUSH)
            termios.tcsetattr(self.fd, termios.TCSANOW, self.old)


class Recorder:
    def __init__(self):
        from macimu import IMU
        if not IMU.available():
            sys.exit("no motion sensor on this Mac (needs Apple Silicon M2 or newer)")
        self.imu = IMU(decimation=1)

    def __enter__(self):
        self.imu.start()
        time.sleep(0.5)
        a, _ = self.read()
        if len(a) < 100:
            self.imu.stop()
            sys.exit("the motion sensor isn't streaming -- try: sudo python3 eval/record.py")
        return self

    def __exit__(self, *exc):
        self.imu.stop()

    def read(self):
        return self.imu.read_accel_timed(), self.imu.read_gyro_timed()

    def collect(self, seconds, acc, gyr, countdown=None):
        end = time.monotonic() + seconds
        last_shown = None
        while True:
            now = time.monotonic()
            a, g = self.read()
            acc += a
            gyr += g
            if now >= end:
                break
            if countdown:
                left = int(end - now) + 1
                if left != last_shown:
                    print(f"\r  {countdown}  {left:2d}s ", end="", flush=True)
                    last_shown = left
            time.sleep(0.02)
        if countdown:
            print("\r" + " " * 60 + "\r", end="", flush=True)
        return acc[-1].t if acc else None

    def record(self, go_seconds, go_label):
        with Quiet():
            time.sleep(C.PREROLL_S)
            self.read()                                   # drop the Enter keypress
            acc, gyr = [], []
            print("  calibrating -- hands off...", flush=True)
            t_go = self.collect(C.CALIB_S, acc, gyr)
            print(f"  >>> GO: {go_label}", flush=True)
            t_end = self.collect(go_seconds, acc, gyr, countdown="recording")
            print("  stop.", flush=True)
        if not acc or not gyr:
            return None
        t0 = acc[0].t
        rel = lambda s: [round(s.t - t0, 6), round(s.x, 7), round(s.y, 7), round(s.z, 7)]
        dur = acc[-1].t - t0
        return {
            "t_calib": 0.0,
            "t_go": round(t_go - t0, 6),
            "t_end": round(t_end - t0, 6),
            "rate_hz": round((len(acc) - 1) / dur, 2) if dur > 0 else None,
            "accel": [rel(s) for s in acc],
            "gyro": [rel(s) for s in gyr],
        }


def build_plan(args):
    rhythms = list(C.RHYTHMS)
    reps, soft_reps = args.reps, 2
    if args.quick:
        rhythms = ["tri_a", "quad_a", "quad_c", "five_a", "shave"]
        reps, soft_reps = min(reps, 2), 1
    negs = list(C.NEGATIVES)
    only = set(args.only.split(",")) if args.only else None
    if only:
        unknown = only - set(C.RHYTHMS) - {n for n, _, _ in C.NEGATIVES}
        if unknown:
            sys.exit(f"unknown --only names: {', '.join(sorted(unknown))}")
        rhythms = [r for r in rhythms if r in only]
        negs = [n for n in negs if n[0] in only]
        soft_reps = 0
    if args.no_negatives:
        negs = []
    if args.no_rhythms:
        rhythms, soft_reps = [], 0

    plan = []
    rounds = [[{"kind": "rhythm", "rhythm": r, "style": "normal", "rep": i + 1} for r in rhythms]
              for i in range(reps)]
    # round-robin (not the same rhythm N times in a row): more realistic variation
    if rounds:
        plan += rounds[0]
    plan += [{"kind": "negative", "scenario": n, "seconds": s, "text": t} for n, s, t in negs]
    for rnd in rounds[1:]:
        plan += rnd
    for i in range(soft_reps):
        plan += [{"kind": "rhythm", "rhythm": r, "style": "soft", "rep": i + 1}
                 for r in C.SOFT_RHYTHMS if r in rhythms]
    return plan


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reps", type=int, default=3, help="repetitions per rhythm (default 3)")
    ap.add_argument("--quick", action="store_true", help="shorter protocol")
    ap.add_argument("--only", help="comma-separated rhythm/negative names to record")
    ap.add_argument("--no-negatives", action="store_true")
    ap.add_argument("--no-rhythms", action="store_true")
    ap.add_argument("--surface", help="what the laptop sits on (asked if omitted)")
    ap.add_argument("--out", default=C.DATA_DIR, help="data dir (default eval/data)")
    ap.add_argument("--session", help="append to an existing session name instead of starting a new one")
    args = ap.parse_args()

    plan = build_plan(args)
    if not plan:
        sys.exit("nothing to record")

    model = sh("sysctl", "-n", "hw.model") or platform.machine()
    session = args.session or datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + model.replace(",", "_")
    sdir = os.path.join(args.out, session)
    surface = args.surface
    if surface is None:
        surface = input("What is the laptop sitting on? [desk] / lap / sofa / other: ").strip() or "desk"
    os.makedirs(sdir, exist_ok=True)
    meta_path = os.path.join(sdir, "session.json")
    if not os.path.exists(meta_path):
        import json
        with open(meta_path, "w") as f:
            json.dump({
                "session": session, "created": datetime.datetime.now().isoformat(timespec="seconds"),
                "model": model, "chip": sh("sysctl", "-n", "machdep.cpu.brand_string"),
                "macos": platform.mac_ver()[0], "surface": surface, "format": C.FORMAT_VERSION,
            }, f, indent=2)

    print(f"\nsession {session}: {len(plan)} clips -> {sdir}")
    print("Knock with a knuckle on the palm rest beside the trackpad, like you would with knockdrop.")
    print("Rhythms: X = knock, each '-' = one beat. Any tempo is fine; keep it natural.")
    print("Only press r (redo) if YOU didn't do what was asked -- not because it felt off.\n")

    existing = len(C.find_clips([sdir]))
    saved = 0
    with Recorder() as rec:
        i = 0
        while i < len(plan):
            item = plan[i]
            n = existing + saved + 1
            print(f"[{i + 1}/{len(plan)}]", end=" ")
            if item["kind"] == "rhythm":
                gaps = C.RHYTHMS[item["rhythm"]]
                soft = " -- GENTLY (soft knocks, still audible)" if item["style"] == "soft" else ""
                print(f"rhythm {item['rhythm']} ({len(gaps) + 1} knocks){soft}")
                print(f"     {C.render_rhythm(gaps)}")
                go_s, go_label = C.RHYTHM_GO_S, "knock the rhythm once, then hands off"
                cid = f"{n:03d}-rhythm-{item['rhythm']}-{item['style']}"
            else:
                print(f"negative: {item['scenario']}")
                print(f"     {item['text']}")
                go_s, go_label = item["seconds"], item["text"].split(" (s = skip)")[0]
                cid = f"{n:03d}-neg-{item['scenario']}"
            ans = input("  Enter = start, s = skip, q = quit > ").strip().lower()
            if ans == "q":
                break
            if ans == "s":
                i += 1
                continue
            data = rec.record(go_s, go_label)
            if data is None:
                print("  no samples recorded -- redoing")
                continue
            ans = input("  Enter = keep, r = redo, d = discard > ").strip().lower()
            if ans == "r":
                continue
            if ans == "d":
                i += 1
                continue
            clip = {"format": C.FORMAT_VERSION, "id": cid, "session": session, "kind": item["kind"]}
            if item["kind"] == "rhythm":
                clip.update(scenario="rhythm", rhythm=item["rhythm"], gaps=C.RHYTHMS[item["rhythm"]],
                            style=item["style"], expected_knocks=len(C.RHYTHMS[item["rhythm"]]) + 1)
            else:
                clip.update(scenario=item["scenario"], expected_knocks=0)
            clip.update(data)
            C.save_clip(os.path.join(sdir, cid + ".json.gz"), clip)
            saved += 1
            i += 1
            print()

    print(f"\nsaved {saved} clip(s) in {sdir}")
    print("run the eval: python3 eval/run_eval.py")


if __name__ == "__main__":
    main()
