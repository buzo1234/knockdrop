"""Candidate knock detectors, evaluated offline before any of them goes into knockdrop.py.

Also keeps earlier detectors around so new data can be compared against them.
"""

import math


class LegacyKnockDetector:
    """knockdrop.py's detector before Nov 2026 (fixed re-arm level, 8 Hz EMA high-pass).

    Streaming knock detector over 6-channel IMU samples (accel g, gyro deg/s).

    Only the gyroscope is used. A knuckle knock makes the chassis twitch: a sharp,
    broadband gyro burst right at impact. The accelerometer is low-pass filtered
    in hardware, rings ~40 Hz for 100+ ms after the impact, and also picks up
    hands landing on / lifting off the palm rest. Mixing it in made real knocks
    and those non-knock events overlap in the recorded eval clips.

    Each gyro axis is high-passed (EMA baseline, `baseline_s`) and z-scored against
    noise measured during calibration. Energy is the mean squared z, smoothed over
    `window_s`, so a knock's alternating-sign burst adds up instead of being judged
    one sample at a time; pure noise sits near 1. A knock is the moment
    sqrt(energy) crosses `threshold`; it re-arms only after it settles below
    threshold/2 for `settle` seconds and at least `refractory` seconds passed.
    """

    CHANNELS = slice(3, 6)   # gyro x, y, z

    def __init__(self, threshold=2.5, refractory=0.08, settle=0.02, baseline_s=0.02,
                 window_s=0.015, rate=800.0):
        self.threshold = threshold
        self.refractory = refractory
        self.settle = settle
        self.alpha = 1.0 / (baseline_s * rate)
        self.beta = 1.0 / (window_s * rate)
        self.base = None
        self.noise = None
        self.energy = 0.0
        self._calib = []
        self.armed = True
        self.last_knock = -1e9
        self.quiet_since = None

    def _highpass(self, v):
        v = v[self.CHANNELS]
        if self.base is None:
            self.base = list(v)
        out = []
        for i, x in enumerate(v):
            self.base[i] += self.alpha * (x - self.base[i])
            out.append(x - self.base[i])
        return out

    def calibrate_feed(self, v):
        self._calib.append(self._highpass(v))

    def finish_calibration(self):
        cols = list(zip(*self._calib[len(self._calib) // 4:])) or [[0.0]] * 3
        self.noise = []
        for c in cols:
            s = sorted(abs(x) for x in c)
            mad = s[len(s) // 2] if s else 0.0
            self.noise.append(max(1.4826 * mad, 0.03))   # deg/s; floor guards a dead-quiet calibration
        self._calib = []

    def feed(self, t, v):
        """Feed one sample; return the knock time if this sample starts a knock."""
        hp = self._highpass(v)
        z2 = sum((x / n) ** 2 for x, n in zip(hp, self.noise)) / len(hp)
        self.energy += self.beta * (z2 - self.energy)
        e = math.sqrt(self.energy)
        if self.armed:
            if e > self.threshold and t - self.last_knock > self.refractory:
                self.armed = False
                self.quiet_since = None
                self.last_knock = t
                return t
        else:
            if e < self.threshold / 2:
                if self.quiet_since is None:
                    self.quiet_since = t
                elif t - self.quiet_since >= self.settle:
                    self.armed = True
            else:
                self.quiet_since = None
        return None
