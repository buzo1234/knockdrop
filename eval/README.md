# knock-detection eval

Record labelled raw-sensor clips once, then replay them through any detector
offline. Detector changes are measured against the same data and don't need
new knocking.

    python3 eval/record.py                      # guided recording session (~12 min; --quick ~5 min)
    python3 eval/run_eval.py                    # score the baseline on eval/data
    python3 eval/run_eval.py --sweep threshold=3,4,6,8
    python3 eval/run_eval.py --detector legacy        # the pre-Nov 2026 detector, for comparison
    python3 eval/run_eval.py -v                 # per-clip: expected vs detected knocks, gaps

## What gets recorded

- **Rhythm clips.** 8 fixed rhythms (3–7 knocks) × 3 reps, round-robin, plus soft-knock reps.
  Ground truth is the rhythm and its knock count. Several rhythms share a knock count, so the eval
  can check whether *different* rhythms get confused.
- **Negative clips.** idle, typing, trackpad, handling, desk bumps, lid, palm-rest shifting, audio.
  Ground truth is zero knocks.

Every clip starts with the app's 1.2 s hands-off calibration and stores raw 800 Hz accel + gyro with
hardware timestamps. The format is described in `clips.py`.

Record on different Macs and surfaces (desk, lap, sofa): each run is its own session, and the
`TAR x-sess` metric pairs clips across sessions. That's the real sender ≠ receiver case.

## Metrics

| metric | meaning | want |
|---|---|---|
| count_ok | rhythm clips with exactly the performed knock count | ↑ |
| capture_ok | the pattern the app would capture has the right count | ↑ |
| TAR | same-rhythm pairs that would match, end to end (= transfer works) | ↑ |
| TAR x-sess | same, only across sessions / Macs | ↑ |
| FAR | different-rhythm, same-count pairs that would match | ↓ |
| FP/min | knocks per minute during negative clips | ↓ (0) |
| false_pat | negative clips that formed a full ≥3-knock pattern | ↓ (0) |

The genuine/impostor rhythm-distance quantiles show how much margin the matcher
tolerance (0.12) has on each side.

## Adding a detector

Add a factory to `DETECTORS` in `run_eval.py`. The detector needs `calibrate_feed(v)`,
`finish_calibration()` and `feed(t, v) -> t | None`, with `v = (ax, ay, az, gx, gy, gz)`.
Then run `--detector NAME`.

## Testing the harness

`python3 eval/synth.py --out /tmp/knock-synth && python3 eval/run_eval.py /tmp/knock-synth`
generates crude synthetic clips. Use them only to check that the eval code works, never to
judge a detector.
