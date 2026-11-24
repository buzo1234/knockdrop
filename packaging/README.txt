knockdrop -- share files between Macs on the same Wi-Fi by knocking the same rhythm.

HAVE HOMEBREW? Use that instead -- updates are `brew update && brew upgrade knockdrop`:
  brew install buzo1234/tap/knockdrop
  (If you installed this zip before, uninstall it first -- see the bottom -- so you
  don't end up with two different `knockdrop` commands.)

INSTALL FROM THIS ZIP (any Mac, Apple Silicon or Intel, macOS 11+)
  1. Unzip, open Terminal in this folder, run:   sh install.sh
  2. Check your Mac:                             knockdrop check
     If it says "local network access: BLOCKED": System Settings -> Privacy & Security ->
     Local Network -> turn on Terminal (or your terminal app), then run the check again.

USE
  Receive:  knockdrop receive                    -> repeat the sender's rhythm; files go to ~/Downloads
  Send:     knockdrop send photo.jpg notes.pdf   -> make up a rhythm
            knockdrop send                       -> share your clipboard (lands on theirs)
  Practice: knockdrop knock                      -> shows each pattern and whether it matches the last

  Macs with the motion sensor (MacBook M2 and newer): knock with a knuckle on the palm rest.
  Macs without it (M1, Intel): tap the SPACE BAR in the Terminal window instead -- this happens
  automatically. Tempo doesn't matter, only the rhythm. At least 3 knocks/taps.
  macOS may ask to allow incoming connections -- allow it, or the sender can't be reached.

  Options: --keys (force space bar), --sensitivity N (default 10, lower = more sensitive),
           --tolerance F (default 0.12), send --multi, receive --out DIR, receive --stay

Traffic is not encrypted and a rhythm is a weak password -- use it on home/office Wi-Fi for
everyday files, not on public networks or for anything sensitive.

Uninstall: sudo rm -rf /usr/local/lib/knockdrop /usr/local/bin/knockdrop
Updates: download the new zip and run `sh install.sh` again. Source and releases:
https://github.com/buzo1234/knockdrop
