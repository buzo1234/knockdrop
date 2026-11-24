#!/usr/bin/env python3
"""Generate synthetic clips in the eval format -- for testing the eval harness itself,
not for judging detectors (real recordings only for that).

    python3 eval/synth.py --out /tmp/knock-synth && python3 eval/run_eval.py /tmp/knock-synth

Noise levels match an idle M3 Pro (accel ~0.0007 g sd, gyro quantized to 0.061 deg/s).
Knocks are damped sinusoids; negatives are crude models of typing, handling, desk bumps.
"""

import argparse
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import clips as C  # noqa: E402

RATE = 793.3
GRAVITY = (0.013, -0.118, -0.974)
ACC_SD, GYR_SD, GYR_Q = 0.0007, 0.07, 0.061035


def events_to_clip(rng, go_s, events, tilt=None):
    """events: list of (t_after_go, amp_g, freq_hz, tau_s, gyro_dps)."""
    n = int((C.CALIB_S + go_s) * RATE)
    acc, gyr = [], []
    for i in range(n):
        t = i / RATE
        ax, ay, az = GRAVITY
        gx = gy = gz = 0.0
        if tilt:
            ang, rate = tilt(t - C.CALIB_S)
            ay += math.sin(ang) * 0.97
            az += (1 - math.cos(ang)) * 0.97
            gx += rate
        for (te, amp, f, tau, gd) in events:
            dt = t - C.CALIB_S - te
            if 0 <= dt < 8 * tau:
                env = math.exp(-dt / tau)
                s = math.sin(2 * math.pi * f * dt)
                az += amp * env * s
                ax += 0.3 * amp * env * math.sin(2 * math.pi * f * 1.3 * dt)
                gy += gd * env * s
        ax += rng.gauss(0, ACC_SD); ay += rng.gauss(0, ACC_SD); az += rng.gauss(0, ACC_SD)
        q = lambda v: round((v + rng.gauss(0, GYR_SD)) / GYR_Q) * GYR_Q
        acc.append([round(t, 6), round(ax, 7), round(ay, 7), round(az, 7)])
        gyr.append([round(t, 6), round(q(gx), 7), round(q(gy), 7), round(q(gz), 7)])
    return {"t_calib": 0.0, "t_go": C.CALIB_S, "t_end": round((n - 1) / RATE, 6), "rate_hz": RATE,
            "accel": acc, "gyro": gyr}


def knock(rng, t, soft=False):
    amp = rng.uniform(0.008, 0.025) if soft else rng.uniform(0.03, 0.15)
    return (t, amp, rng.uniform(120, 250), rng.uniform(0.006, 0.012), amp * rng.uniform(20, 60))


def rhythm_events(rng, gaps, soft):
    beat = rng.uniform(0.22, 0.45)
    t = rng.uniform(0.5, 1.5)
    out = [knock(rng, t, soft)]
    for g in gaps:
        t += g * beat * rng.gauss(1, 0.07)
        out.append(knock(rng, t, soft))
    return out


def negative(rng, name, secs):
    ev, tilt = [], None
    if name == "typing":
        t = 0.3
        while t < secs - 0.3:
            ev.append((t, rng.uniform(0.001, 0.006), rng.uniform(150, 300), 0.004, rng.uniform(0.5, 2)))
            t += rng.expovariate(7)
    elif name == "desk":
        for _ in range(8):
            ev.append((rng.uniform(0.5, secs - 0.5), rng.uniform(0.003, 0.02), rng.uniform(40, 90), 0.02, 1.0))
    elif name == "handling":
        def tilt(t):
            if t < 0:
                return 0.0, 0.0
            ph = (t % 4.0) / 4.0
            ang = 0.25 * math.sin(math.pi * ph) ** 2
            rate = math.degrees(0.25 * math.pi / 4.0 * math.sin(2 * math.pi * ph))
            return ang, rate
        ev += [(4.0 * k + 3.9, rng.uniform(0.02, 0.06), 80, 0.015, 5.0) for k in range(int(secs // 4))]
    return ev, tilt


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="data dir to write a synthetic session into")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--sessions", type=int, default=2, help="separate sessions (stand-ins for two Macs)")
    args = ap.parse_args()
    rng = random.Random(args.seed)
    for si in range(args.sessions):
        session = f"synth-{args.seed}-{si}"
        sdir = os.path.join(args.out, session)
        n = 0
        def save(clip):
            nonlocal n
            n += 1
            clip.update(format=C.FORMAT_VERSION, session=session)
            clip["id"] = f"{n:03d}-" + clip["id"]
            C.save_clip(os.path.join(sdir, clip["id"] + ".json.gz"), clip)
        for rep in range(args.reps):
            for name, gaps in C.RHYTHMS.items():
                for style in ["normal"] + (["soft"] if name in C.SOFT_RHYTHMS and rep == 0 else []):
                    clip = events_to_clip(rng, C.RHYTHM_GO_S, rhythm_events(rng, gaps, style == "soft"))
                    clip.update(id=f"rhythm-{name}-{style}", kind="rhythm", scenario="rhythm", rhythm=name,
                                gaps=gaps, style=style, expected_knocks=len(gaps) + 1)
                    save(clip)
        for name, secs, _ in C.NEGATIVES:
            if name in ("idle", "typing", "desk", "handling"):
                ev, tilt = negative(rng, name, secs)
                clip = events_to_clip(rng, secs, ev, tilt)
                clip.update(id=f"neg-{name}", kind="negative", scenario=name, expected_knocks=0)
                save(clip)
        print(f"wrote {n} clips to {sdir}")


if __name__ == "__main__":
    main()
