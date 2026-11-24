<div align="center">

# 👊 knockdrop

**Knock on your MacBook. Your teammate knocks the same rhythm on theirs. The files fly over.**

Bump-style file sharing between Macs on the same Wi-Fi, using the hidden motion sensor in Apple Silicon MacBooks.

`macOS` · `zero dependencies` · `one Python file` · `MIT`

```
  knock knock . knock ...... knock . knock

  o----------o----o--------------------o----------o   (5 knocks, 1.80s)
```

</div>

---

## Install

```sh
brew install buzo1234/tap/knockdrop
knockdrop check
```

**Update:** `brew update && brew upgrade knockdrop`

`brew update` makes Homebrew check the tap for a new version right away. Without it, Homebrew only checks about once a day, so `brew upgrade` alone can miss a fresh release.

It runs on the Python that ships with macOS, so Homebrew installs nothing else alongside it.

<details>
<summary>Without Homebrew</summary>

```sh
git clone https://github.com/buzo1234/knockdrop ~/.knockdrop
sudo mkdir -p /usr/local/bin && sudo ln -sf ~/.knockdrop/knockdrop /usr/local/bin/knockdrop
```

Update with `git -C ~/.knockdrop pull`. If macOS asks you to install the Command Line Tools the first time, say yes.

</details>

## Use it

**On the sending Mac:**

```console
$ knockdrop send photo.jpg notes.pdf
sharing 2 file(s), 3.4 MB

knock your secret rhythm on the laptop...
  o----------o----o--------------------o----------o   (5 knocks, 1.80s)
  share with this rhythm? [Enter = yes / r = redo]

waiting for someone on this Wi-Fi to knock the same rhythm (expires in 5 min, Ctrl+C to cancel)
  bobs-macbook (192.168.1.42) matched -- sending...
  sent to bobs-macbook
```

**On the receiving Mac:**

```console
$ knockdrop receive
nearby offers: alices-macbook (5 knocks)
  o----------o----o--------------------o----------o   (5 knocks, 1.86s)

received from alices-macbook:
  ~/Downloads/photo.jpg  (3.2 MB, 9.8 MB/s)
  ~/Downloads/notes.pdf  (212 KB, 9.8 MB/s)
```

Knock with a knuckle on the palm rest or beside the trackpad, at least 3 times. **Tempo doesn't matter, only the shape of the rhythm**, so it still matches when the other person knocks it faster or slower.

| Command | What it does |
|---|---|
| `knockdrop send FILE...` | Knock a rhythm and offer the files behind it |
| `knockdrop receive` | Knock the sender's rhythm; files land in `~/Downloads` |
| `knockdrop knock` | Practice mode: shows each pattern and whether it matches the previous one |
| `knockdrop check` | Self-test for the sensor, ports and Local Network permission |

<details>
<summary><b>Options</b></summary>

| Flag | |
|---|---|
| `--keys` | Tap the space bar instead of knocking |
| `--sensitivity N` | Knock threshold, default `2.5`. Lower is more sensitive |
| `--tolerance F` | How different two rhythms may be and still match, default `0.12` |
| `send --multi` | Keep sharing after the first receiver |
| `send -y` | Don't ask to confirm the rhythm |
| `receive --out DIR` | Save somewhere other than `~/Downloads` |
| `receive --stay` | Keep receiving after the first transfer |

</details>

### Which Macs?

| Mac | Input |
|---|---|
| MacBook with M2 or newer | 👊 Knock on the laptop body |
| M1, Intel, desktops | ⌨️ Tap the space bar (switches automatically) |

Any mix works: a knocker can share with a space-bar tapper.

## How it works

```
   SENDER                                         RECEIVER
   knocks o--o-o-----o--o
   opens a TCP port
   beacon every 1s ─── UDP :47477 ────────────▶   sees "alices-macbook, 5 knocks, 2 files"
   (name, port, knock count, file list;           knocks o--o-o-----o--o
    never the rhythm)
                    ◀──── knock timings ──────     sends its timings to offers with
                                                   the same knock count
   compares rhythms
   match? ───────────── files ────────────────▶   checks each SHA-256, saves
```

1. **Reading knocks.** The accelerometer and gyroscope in Apple Silicon MacBooks aren't exposed by any public API. knockdrop reads them at 800 Hz through the bundled [`macimu`](https://github.com/olvvier/apple-silicon-accelerometer) library. It calibrates on 1.2 s of stillness, then counts short bursts of gyroscope energy above the noise floor as knocks. A knock twitches the chassis sharply; hands landing on the palm rest mostly show up on the accelerometer, so that's ignored.
2. **Comparing rhythms.** Each gap between knocks becomes a fraction of the whole pattern, so a slow and a fast version of the same rhythm look identical. Two patterns match when every fraction is within the tolerance.
3. **Finding each other.** The sender announces itself with UDP multicast and broadcast. The rhythm is never broadcast; only the sender ever compares it.
4. **Transfer.** Files stream over TCP and are checked against their SHA-256 before saving. An offer closes after one transfer, 8 wrong attempts, or 5 minutes.

## Heads-up

> [!WARNING]
> Traffic isn't encrypted, and a knock rhythm is a weak password. It's fine for photos and notes on home or office Wi-Fi. Don't use it on public networks or for anything sensitive.

- macOS may ask to allow incoming connections, or Local Network access for your terminal app. Allow both. `knockdrop check` tells you if Local Network access is blocked (System Settings → Privacy & Security → Local Network).
- On some Macs the sensor only streams as root. knockdrop then re-runs itself with `sudo` and asks for your password.
- Typing or bumping the desk while knocking adds extra knocks. Keep your other hand off the laptop.
- Mixed short and long gaps make a rhythm harder to guess than an even beat.

## Development

```
knockdrop.py      the whole app: knock detection, discovery, transfer
macimu/           vendored sensor library (MIT, see macimu/LICENSE)
eval/             record labelled knock clips and score detectors offline
build.sh          standalone universal .zip via PyInstaller (no Python needed)
packaging/        installer and README for that .zip, Homebrew formula template
```

**Releases are automatic.** Every push to `main` that changes the app (`knockdrop.py`, `knockdrop`, `macimu/`) bumps the patch version. It tags `vX.Y.Z`, publishes a GitHub release, installs the new formula with Homebrew on a macOS runner, and only then pushes it to [buzo1234/homebrew-tap](https://github.com/buzo1234/homebrew-tap). For a minor or major bump, run the **release** workflow by hand from the Actions tab.

To try send and receive on one Mac without knocking, script the knock times:

```sh
./knockdrop --pattern 0,0.4,0.6,1.4,1.8 send -y somefile &
./knockdrop --pattern 0,0.42,0.63,1.45,1.86 receive --out /tmp/kd
```

See [`eval/README.md`](eval/README.md) to record your own knock clips and tune the detector.

## Credits

Sensor access comes from [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer) (MIT). The idea is borrowed from Bump, which did this with phones in 2009.

## License

[MIT](LICENSE)
