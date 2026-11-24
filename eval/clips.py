"""Clip format, rhythm library and scenarios shared by the recorder and the eval.

A clip is one labelled recording: raw accel (g) + gyro (deg/s) with hardware
timestamps, relative to the start of its calibration window.

    t_calib = 0      hands off -- the detector calibrates on [t_calib, t_go)
    t_go             the scripted action starts (knock the rhythm / type / ...)
    t_end            recording stops

Stored as gzipped JSON: eval/data/<session>/<clip id>.json.gz, plus
eval/data/<session>/session.json with session-level metadata.
"""

import gzip
import json
import os

FORMAT_VERSION = 1
HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, "data")

CALIB_S = 1.2          # matches IMUKnocks.__enter__ in knockdrop.py
PREROLL_S = 0.5        # let the Enter keypress die down before calibrating

# Rhythms as gap lengths in beats. Several share a knock count so the eval can
# measure whether different rhythms get confused (impostor pairs). None are
# "too regular" (knockdrop send rejects those).
RHYTHMS = {
    "tri_a":  [1, 2],
    "tri_b":  [2, 1],
    "quad_a": [1, 1, 2],
    "quad_b": [2, 1, 1],
    "quad_c": [1, 2, 1],
    "five_a": [1, 1, 2, 2],
    "five_b": [2, 2, 1, 1],
    "shave":  [2, 1, 1, 2, 4, 2],   # shave-and-a-haircut, two bits
}
SOFT_RHYTHMS = ["quad_a", "five_a"]   # also recorded with gentle knocks

RHYTHM_GO_S = 8.0

# Things that should produce zero knocks. (name, seconds, instruction)
NEGATIVES = [
    ("idle", 12, "Hands off the laptop. Don't touch anything."),
    ("typing", 15, "Type normally on the laptop keyboard (anything -- it's discarded)."),
    ("trackpad", 15, "Use the trackpad: scroll, swipe, click a few times."),
    ("handling", 15, "Pick the laptop up a little, tilt it, set it back down. Repeat."),
    ("desk", 15, "Tap / bump the table or desk NEAR the laptop (not the laptop itself)."),
    ("lid", 12, "Adjust the lid angle back and forth a few times."),
    ("palmrest", 15, "Rest your wrists on the palm rest, shift around, lift them, rest them again."),
    ("audio", 15, "Play music with bass through the laptop speakers, fairly loud. (s = skip)"),
]


def render_rhythm(gaps):
    """[1, 2] -> 'X-X--X' (one dash per beat)."""
    return "X" + "".join("-" * g + "X" for g in gaps)


def save_clip(path, clip):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with gzip.open(tmp, "wt") as f:
        json.dump(clip, f, separators=(",", ":"))
    os.replace(tmp, path)


def load_clip(path):
    with gzip.open(path, "rt") as f:
        clip = json.load(f)
    clip["path"] = path
    return clip


def find_clips(paths):
    """Expand files / session dirs / the data dir into sorted clip paths."""
    out = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                out += [os.path.join(root, f) for f in files if f.endswith(".json.gz")]
        elif p.endswith(".json.gz"):
            out.append(p)
    return sorted(set(out))


def load_session_meta(clip_path):
    p = os.path.join(os.path.dirname(clip_path), "session.json")
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}
