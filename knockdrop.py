#!/usr/bin/env python3
"""knockdrop -- share files between Macs on the same Wi-Fi by knocking the same rhythm.

    knockdrop send FILE [FILE ...]     knock a rhythm, wait for someone to repeat it
    knockdrop send                     same, but share what's on your clipboard
    knockdrop receive                  knock the sender's rhythm to get the files
    knockdrop menubar                  receive in the background: just knock, no command
    knockdrop knock                    practice knocking and check that two rhythms match
    knockdrop check                    check the sensor and network on this Mac

Knocks are read from the motion sensor (accelerometer + gyroscope). Macs without
it (M1, Intel) automatically use the space bar instead; --keys forces that.

Update with `brew update && brew upgrade knockdrop`. Docs: https://github.com/buzo1234/knockdrop
"""
__version__ = "dev"  # set by the Homebrew formula on release

import argparse
import errno
import hashlib
import json
import math
import multiprocessing
import os
import secrets
import select
import socket
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty

MCAST_GRP = "239.255.77.77"
BEACON_PORT = 47477
BEACON_EVERY = 1.0
OFFER_SEEN_TTL = 4.0
OFFER_LIFETIME = 300
MAX_FAILED_CLAIMS = 8
MIN_KNOCKS, MAX_KNOCKS = 3, 16
PATTERN_END_QUIET = 1.5
CHUNK = 1 << 16
AGENT_MAX_TRIES = 3          # wrong rhythms the background receiver sends to one offer, then it gives up
TABLE_WINDOW = 20.0          # table mode: a rhythm felt this long before an offer appears can claim it
APP_ID = "io.github.buzo1234.knockdrop"
HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------- events (for the menu bar app)

_events_out = None


def enable_events():
    """Machine-readable mode: JSON event lines on stdout, human-readable text moves to stderr."""
    global _events_out
    _events_out = sys.stdout
    sys.stdout = sys.stderr


def emit(event, **data):
    if _events_out is None:
        return
    data["event"] = event
    try:
        _events_out.write(json.dumps(data) + "\n")
        _events_out.flush()
    except (OSError, ValueError):
        os._exit(0)   # whoever was reading us is gone


def read_parent_commands(on_command=None):
    """The menu bar app holds our stdin open and may send JSON command lines on it.
    EOF means the app quit or crashed, so we exit too."""
    if sys.stdin is None or sys.stdin.isatty():
        return

    def watch():
        try:
            for line in iter(sys.stdin.readline, ""):
                if on_command:
                    try:
                        c = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(c, dict):
                        on_command(c)
        except (OSError, ValueError):
            pass
        os._exit(0)
    threading.Thread(target=watch, daemon=True).start()


# ---------------------------------------------------------------- knock detection

class KnockDetector:
    """Streaming knock detector over 6-channel IMU samples (accel g, gyro deg/s).

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


class SensorSilent(RuntimeError):
    """The sensor opened but sent no samples (this macOS wants root for it)."""


class IMUKnocks:
    """Yields knock times from the built-in motion sensor."""

    def __init__(self, threshold):
        self.threshold = threshold
        self.imu = None
        self._acc, self._gyr = [], []

    def start(self):
        """Start the sensor and calibrate on ~1.2 s of samples. Raises SensorSilent if nothing streams."""
        from macimu import IMU
        self.imu = IMU(decimation=1)
        self.det = KnockDetector(threshold=self.threshold)
        self.imu.start()
        time.sleep(0.3)
        self._drain()
        end, n = time.time() + 1.2, 0
        while time.time() < end:
            for t, v in self._pairs():
                self.det.calibrate_feed(v)
                n += 1
            time.sleep(0.005)
        if n < 100:
            self.stop()
            raise SensorSilent()
        self.det.finish_calibration()

    def stop(self):
        if self.imu is not None:
            self.imu.stop()
            self.imu = None

    def __enter__(self):
        print("calibrating -- keep hands off the laptop for a second...", flush=True)
        emit("calibrating")
        try:
            self.start()
        except SensorSilent:
            if os.geteuid() != 0 and _events_out is None:
                relaunch_with_sudo()
            emit("error", message="the motion sensor isn't sending data")
            sys.exit("the motion sensor isn't sending data -- tap the space bar instead by adding "
                     "--keys (e.g. knockdrop receive --keys)")
        return self

    def __exit__(self, *exc):
        self.stop()

    def _drain(self):
        self.imu.read_accel_timed()
        self.imu.read_gyro_timed()
        self._acc, self._gyr = [], []

    def _pairs(self):
        self._acc.extend(self.imu.read_accel_timed())
        self._gyr.extend(self.imu.read_gyro_timed())
        n = min(len(self._acc), len(self._gyr))
        out = [(a[0], (a[1], a[2], a[3], g[1], g[2], g[3])) for a, g in zip(self._acc[:n], self._gyr[:n])]
        del self._acc[:n], self._gyr[:n]
        return out

    def flush(self):
        self._drain()
        self.det.armed, self.det.last_knock = True, -1e9

    def poll(self):
        knocks = []
        for t, v in self._pairs():
            k = self.det.feed(t, v)
            if k is not None:
                knocks.append(time.monotonic())   # wall clock: pattern timing only needs relative times
        return knocks


class KeyKnocks:
    """Yields knock times from space-bar presses (no sensor needed)."""

    def __enter__(self):
        self.fd = sys.stdin.fileno()
        self.old = termios.tcgetattr(self.fd)
        tty.setcbreak(self.fd)
        return self

    def __exit__(self, *exc):
        termios.tcsetattr(self.fd, termios.TCSADRAIN, self.old)

    def flush(self):
        termios.tcflush(self.fd, termios.TCIFLUSH)

    def poll(self):
        knocks = []
        while select.select([sys.stdin], [], [], 0)[0]:
            if os.read(self.fd, 1) == b" ":
                knocks.append(time.monotonic())
        return knocks


def capture_pattern(source, prompt):
    """Block until a full knock pattern is captured; return knock times (relative, seconds)."""
    source.flush()
    print(prompt, flush=True)
    emit("knock_now")
    knocks = []
    while True:
        new = source.poll()
        for k in new:
            knocks.append(k)
            print("  knock" + (" " * 2) + str(len(knocks)), flush=True)
            emit("knock", n=len(knocks))
        if knocks and time.monotonic() - knocks[-1] > PATTERN_END_QUIET:
            if len(knocks) < MIN_KNOCKS:
                print(f"  only {len(knocks)} knock(s) -- need at least {MIN_KNOCKS}. again:", flush=True)
                emit("pattern_rejected", knocks=len(knocks), reason=f"need at least {MIN_KNOCKS} knocks")
                knocks = []
                continue
            if len(knocks) > MAX_KNOCKS:
                print(f"  {len(knocks)} knocks -- max is {MAX_KNOCKS}. again:", flush=True)
                emit("pattern_rejected", knocks=len(knocks), reason=f"at most {MAX_KNOCKS} knocks")
                knocks = []
                continue
            return [k - knocks[0] for k in knocks]
        time.sleep(0.005)


# ---------------------------------------------------------------- pattern matching

def intervals(times):
    return [b - a for a, b in zip(times, times[1:])]


def normalized(times):
    iv = intervals(times)
    total = sum(iv) or 1e-9
    return [x / total for x in iv]


def pattern_distance(a, b):
    """Tempo-invariant rhythm distance (0 = identical); None if knock counts differ."""
    if len(a) != len(b):
        return None
    na, nb = normalized(a), normalized(b)
    return max(abs(x - y) for x, y in zip(na, nb))


def patterns_match(a, b, tolerance):
    d = pattern_distance(a, b)
    if d is None:
        return False
    tempo = (a[-1] or 1e-9) / (b[-1] or 1e-9)
    return d <= tolerance and 0.5 <= tempo <= 2.0


def is_too_regular(times):
    iv = intervals(times)
    return max(iv) / max(min(iv), 1e-9) < 1.6


def render(times, width=48):
    span = times[-1] or 1e-9
    line = ["-"] * (width + 1)
    for t in times:
        line[round(t / span * width)] = "o"
    return "".join(line) + f"   ({len(times)} knocks, {span:.2f}s)"


# ---------------------------------------------------------------- networking

def send_json(sock, obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def recv_json(f):
    line = f.readline(65536)
    if not line:
        raise ConnectionError("connection closed")
    return json.loads(line)


def hostname():
    return socket.gethostname().split(".")[0]


LOCAL_NETWORK_HELP = ("macOS is blocking local network access for this program.\n"
                      "  Fix: System Settings -> Privacy & Security -> Local Network -> turn on your\n"
                      "  terminal app (Terminal / iTerm / ...), then run knockdrop again.")


def broadcast_addresses():
    """Subnet-directed broadcast addresses of active interfaces (e.g. 192.168.1.255)."""
    try:
        out = subprocess.run(["/sbin/ifconfig"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    addrs = []
    for line in out.splitlines():
        parts = line.split()
        if parts[:1] == ["inet"] and "broadcast" in parts:
            b = parts[parts.index("broadcast") + 1]
            if b not in addrs:
                addrs.append(b)
    return addrs


def beacon_destinations():
    return [(MCAST_GRP, BEACON_PORT), ("255.255.255.255", BEACON_PORT)] + \
           [(b, BEACON_PORT) for b in broadcast_addresses()]


def local_network_blocked():
    """True when macOS Local Network privacy denies this process (sendto -> EHOSTUNREACH)."""
    s = beacon_socket()
    try:
        s.sendto(b"{}", (MCAST_GRP, BEACON_PORT))
        return False
    except OSError as e:
        return e.errno in (errno.EHOSTUNREACH, errno.EPERM, errno.EACCES)
    finally:
        s.close()


def beacon_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
    return s


def listen_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.bind(("", BEACON_PORT))
    mreq = struct.pack("4s4s", socket.inet_aton(MCAST_GRP), socket.inet_aton("0.0.0.0"))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    s.settimeout(0.5)
    return s


def file_digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


# ---------------------------------------------------------------- clipboard

# JavaScript for Automation (osascript) gives full NSPasteboard access with no dependencies.
READ_CLIPBOARD_JS = r"""
ObjC.import('AppKit');
function run(argv) {
  var dir = argv[0], pb = $.NSPasteboard.generalPasteboard;
  var opts = $.NSDictionary.dictionaryWithObjectForKey($.NSNumber.numberWithBool(true),
                                                       'NSPasteboardURLReadingFileURLsOnlyKey');
  var urls = pb.readObjectsForClassesOptions($.NSArray.arrayWithObject($.NSURL), opts);
  if (!urls.isNil() && urls.count > 0) {
    var paths = [];
    for (var i = 0; i < urls.count; i++) paths.push(urls.objectAtIndex(i).path.js);
    return JSON.stringify({kind: 'files', paths: paths});
  }
  var data = pb.dataForType('public.png');
  if (data.isNil()) {
    var tiff = pb.dataForType('public.tiff');
    if (!tiff.isNil()) {
      var rep = $.NSBitmapImageRep.imageRepWithData(tiff);
      if (!rep.isNil()) data = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $.NSDictionary.dictionary);
    }
  }
  if (!data.isNil()) {
    var p = dir + '/Clipboard image.png';
    data.writeToFileAtomically(p, true);
    return JSON.stringify({kind: 'image', path: p});
  }
  var s = pb.stringForType('public.utf8-plain-text');
  if (!s.isNil() && s.length > 0) {
    var t = dir + '/Clipboard text.txt';
    s.writeToFileAtomicallyEncodingError(t, true, $.NSUTF8StringEncoding, null);
    return JSON.stringify({kind: 'text', path: t});
  }
  return JSON.stringify({kind: 'empty'});
}
"""

WRITE_CLIPBOARD_JS = r"""
ObjC.import('AppKit');
function run(argv) {
  var kind = argv[0], pb = $.NSPasteboard.generalPasteboard, objs = $.NSMutableArray.array;
  if (kind === 'text') {
    var s = $.NSString.stringWithContentsOfFileEncodingError(argv[1], $.NSUTF8StringEncoding, null);
    if (s.isNil()) return 'fail';
    var ti = $.NSPasteboardItem.alloc.init;
    ti.setStringForType(s, 'public.utf8-plain-text');
    objs.addObject(ti);
  } else if (kind === 'image') {
    var png = $.NSData.dataWithContentsOfFile(argv[1]), img = $.NSImage.alloc.initWithContentsOfFile(argv[1]);
    if (png.isNil() || img.isNil()) return 'fail';
    var ii = $.NSPasteboardItem.alloc.init;
    ii.setDataForType(png, 'public.png');
    ii.setDataForType(img.TIFFRepresentation, 'public.tiff');
    objs.addObject(ii);
  } else if (kind === 'files') {
    for (var i = 1; i < argv.length; i++) {   // explicit items: NSURL objects are lazy and vanish when we exit
      var fi = $.NSPasteboardItem.alloc.init;
      fi.setStringForType($.NSURL.fileURLWithPath(argv[i]).absoluteString, 'public.file-url');
      objs.addObject(fi);
    }
  } else {
    return 'fail';
  }
  pb.clearContents;
  if (!pb.writeObjects(objs)) return 'fail';
  // read it back before exiting: otherwise the last item can be lost when osascript quits mid-write
  for (var w = 0; w < 50 && Number(pb.pasteboardItems.count) < Number(objs.count); w++) delay(0.02);
  delay(0.05);
  return Number(pb.pasteboardItems.count) === Number(objs.count) ? 'ok' : 'fail';
}
"""

CLIPBOARD_KINDS = ("text", "image", "files")


def _jxa(script, *args):
    cmd = ["/usr/bin/osascript", "-l", "JavaScript", "-e", script, *args]
    if os.geteuid() == 0 and os.environ.get("SUDO_USER"):   # the clipboard belongs to the real user
        cmd = ["/usr/bin/sudo", "-u", os.environ["SUDO_USER"]] + cmd
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def read_clipboard(folder):
    """What's on the clipboard: {"kind": "files", "paths": [...]}, {"kind": "image"|"text", "path": ...}
    (written into `folder`), or {"kind": "empty"}."""
    out = _jxa(READ_CLIPBOARD_JS, folder)
    try:
        return json.loads(out) if out else {"kind": "empty"}
    except ValueError:
        return {"kind": "empty"}


def set_clipboard(kind, paths):
    return _jxa(WRITE_CLIPBOARD_JS, kind, *paths) == "ok"


def preview_text(path, limit=80):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            s = " ".join(f.read(limit * 4).split())
    except OSError:
        return ""
    return s if len(s) <= limit else s[:limit - 1] + "…"


def describe_share(kind, files):
    total = human(sum(f["size"] for f in files))
    if kind == "text":
        return f"clipboard text ({total})"
    if kind == "image":
        return f"clipboard image ({total})"
    what = f"{len(files)} copied file(s)" if kind == "files" else f"{len(files)} file(s)"
    return f"{what}, {total}"


# ---------------------------------------------------------------- send

class Offer:
    def __init__(self, paths, pattern, tolerance, multi, clipboard=None):
        self.id = secrets.token_hex(8)
        self.pattern = pattern
        self.tolerance = tolerance
        self.multi = multi
        self.clipboard = clipboard
        self.files = [{"name": os.path.basename(p), "size": os.path.getsize(p),
                       "sha256": file_digest(p), "path": p} for p in paths]
        self.failed = 0
        self.done = threading.Event()      # stop accepting / beaconing
        self.claimed = threading.Event()   # single-receiver mode: a transfer is in progress
        self.lock = threading.Lock()
        self.expires = time.time() + OFFER_LIFETIME

    def beacon(self, port):
        b = {"app": "knockdrop", "v": 1, "id": self.id, "from": hostname(), "port": port,
             "knocks": len(self.pattern),
             "files": [{"name": f["name"], "size": f["size"]} for f in self.files]}
        if self.clipboard:
            b["clipboard"] = self.clipboard
        return b

    def manifest(self):
        items = []
        for f in self.files:
            item = {k: f[k] for k in ("name", "size", "sha256")}
            if self.clipboard:
                item["clipboard"] = self.clipboard   # receivers put it on their clipboard
            items.append(item)
        return items


def serve_claim(conn, addr, offer):
    with conn:
        conn.settimeout(30)
        f = conn.makefile("rb")
        try:
            claim = recv_json(f)
        except (ValueError, ConnectionError, socket.timeout):
            return
        who = str(claim.get("from", addr[0]))[:64]
        with offer.lock:
            if offer.done.is_set() or offer.claimed.is_set():
                send_json(conn, {"ok": False, "reason": "offer closed"}); return
            if claim.get("id") != offer.id:
                send_json(conn, {"ok": False, "reason": "unknown offer"}); return
            pattern = claim.get("pattern")
            ok = (isinstance(pattern, list) and MIN_KNOCKS <= len(pattern) <= MAX_KNOCKS
                  and all(isinstance(x, (int, float)) for x in pattern)
                  and patterns_match(offer.pattern, pattern, offer.tolerance))
            if not ok:
                offer.failed += 1
                left = MAX_FAILED_CLAIMS - offer.failed
                print(f"  {who} ({addr[0]}) knocked a different rhythm  [{left} attempts left]", flush=True)
                emit("wrong", who=who, left=left)
                send_json(conn, {"ok": False, "reason": "rhythm doesn't match"})
                if left <= 0:
                    print("too many wrong attempts -- closing the offer", flush=True)
                    emit("closed", reason="too many wrong attempts")
                    offer.done.set()
                return
            if not offer.multi:
                offer.claimed.set()
        print(f"  {who} ({addr[0]}) matched -- sending...", flush=True)
        emit("sending", who=who)
        send_json(conn, {"ok": True, "from": hostname(), "files": offer.manifest()})
        try:
            for item in offer.files:
                with open(item["path"], "rb") as src:
                    for chunk in iter(lambda: src.read(CHUNK), b""):
                        conn.sendall(chunk)
            conn.shutdown(socket.SHUT_WR)
            conn.recv(1)  # wait for the receiver to close
            print(f"  sent to {who}", flush=True)
            emit("sent", who=who)
            if not offer.multi:
                offer.done.set()
        except OSError as e:
            print(f"  transfer to {who} failed: {e} -- still waiting", flush=True)
            emit("transfer_failed", who=who, message=str(e))
            offer.claimed.clear()   # let them retry


def cmd_send(args, source):
    kind, tmpdir = None, None
    try:
        if args.files:
            paths = [os.path.abspath(os.path.expanduser(p)) for p in args.files]
        else:   # nothing named: share whatever is on the clipboard
            tmpdir = tempfile.mkdtemp(prefix="knockdrop-")
            give_to_user(tmpdir)
            clip = read_clipboard(tmpdir)
            kind = clip.get("kind")
            if kind not in CLIPBOARD_KINDS:
                emit("error", message="The clipboard is empty")
                sys.exit("nothing to share: the clipboard is empty "
                         "(copy something first, or name files: knockdrop send FILE...)")
            paths = clip["paths"] if kind == "files" else [clip["path"]]
        for p in paths:
            if not os.path.isfile(p):
                emit("error", message=f"Not a file: {os.path.basename(p)}")
                sys.exit(f"not a file: {p}" + (" (folders aren't supported yet)" if os.path.isdir(p) else ""))
        files = [{"size": os.path.getsize(p)} for p in paths]
        what = describe_share(kind, files)
        print(f"sharing {what}" + (f': "{preview_text(paths[0], 50)}"' if kind == "text" else ""))
        emit("sharing", what=what, kind=kind or "files")
        _send(args, source, paths, kind)
    finally:
        if tmpdir:
            shutil.rmtree(tmpdir, ignore_errors=True)


def _send(args, source, paths, kind):
    while True:
        pattern = args.pattern or capture_pattern(source, "\nknock your secret rhythm on the laptop...")
        print("  " + render(pattern))
        if is_too_regular(pattern):
            print("  tip: evenly spaced knocks are easy to guess -- mix short and long gaps")
        if args.pattern or args.yes or _events_out is not None:
            break
        ans = input("  share with this rhythm? [Enter = yes / r = redo] ").strip().lower()
        if ans != "r":
            break

    offer = Offer(paths, pattern, args.tolerance, args.multi, clipboard=kind)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", 0))
    srv.listen(8)
    srv.settimeout(0.5)
    port = srv.getsockname()[1]

    def beacons():
        s = beacon_socket()
        msg = json.dumps(offer.beacon(port)).encode()
        dests, warned, rounds = beacon_destinations(), False, 0
        while not offer.done.is_set() and time.time() < offer.expires:
            sent = 0
            for dest in dests:
                try:
                    s.sendto(msg, dest)
                    sent += 1
                except OSError:
                    pass
            if not sent and not warned:
                print("  can't announce the offer on the network. " + LOCAL_NETWORK_HELP, flush=True)
                emit("error", message="Local Network access is blocked")
                warned = True
            rounds += 1
            if rounds % 10 == 0:
                dests = beacon_destinations()   # follow Wi-Fi changes
            offer.done.wait(BEACON_EVERY)
    threading.Thread(target=beacons, daemon=True).start()

    print(f"\nwaiting for someone on this Wi-Fi to knock the same rhythm "
          f"(expires in {OFFER_LIFETIME // 60} min, Ctrl+C to cancel)", flush=True)
    emit("waiting", knocks=len(pattern), expires_in=OFFER_LIFETIME, times=pattern, multi=args.multi)
    workers = []
    try:
        while not offer.done.is_set() and time.time() < offer.expires:
            try:
                conn, addr = srv.accept()
            except socket.timeout:
                continue
            w = threading.Thread(target=serve_claim, args=(conn, addr, offer), daemon=True)
            w.start()
            workers.append(w)
        if time.time() >= offer.expires and not offer.done.is_set():
            print("offer expired")
            emit("expired")
        for w in workers:          # let an in-flight transfer finish
            w.join()
    except KeyboardInterrupt:
        print("\ncancelled")
    finally:
        offer.done.set()
        srv.close()


# ---------------------------------------------------------------- receive

def unique_path(folder, name):
    name = os.path.basename(name).lstrip(".") or "file"
    base, ext = os.path.splitext(name)
    p, i = os.path.join(folder, name), 1
    while os.path.exists(p) or os.path.exists(p + ".part"):
        p = os.path.join(folder, f"{base} ({i}){ext}")
        i += 1
    return p


def give_to_user(path):
    uid, gid = os.environ.get("SUDO_UID"), os.environ.get("SUDO_GID")
    if os.geteuid() == 0 and uid and gid:
        os.chown(path, int(uid), int(gid))


def try_claim(offer, addr, pattern, out_dir):
    """Ask the sender for an offer with our rhythm. Returns (True, items) or (False, reason).
    Each item: {"name", "size", "secs", "path" (None when it only went to the clipboard),
    "clipboard" (kind or None), "copied" (on our clipboard), "preview" (text only)}."""
    with socket.create_connection((addr, offer["port"]), timeout=10) as conn:
        send_json(conn, {"id": offer["id"], "pattern": pattern, "from": hostname()})
        f = conn.makefile("rb")
        resp = recv_json(f)
        if not resp.get("ok"):
            return False, resp.get("reason", "rejected")
        conn.settimeout(60)
        saved = []
        for item in resp["files"]:
            dest = unique_path(out_dir, item["name"])
            tmp = dest + ".part"
            h, left, t0 = hashlib.sha256(), int(item["size"]), time.time()
            with open(tmp, "wb") as out:
                while left:
                    chunk = f.read(min(CHUNK, left))
                    if not chunk:
                        os.remove(tmp)
                        raise ConnectionError("sender disconnected mid-transfer")
                    out.write(chunk); h.update(chunk); left -= len(chunk)
            if h.hexdigest() != item["sha256"]:
                os.remove(tmp)
                raise ValueError(f"{item['name']}: checksum mismatch")
            os.rename(tmp, dest)
            give_to_user(dest)
            kind = item.get("clipboard")
            saved.append({"name": item["name"], "size": item["size"], "secs": time.time() - t0, "path": dest,
                          "clipboard": kind if kind in CLIPBOARD_KINDS else None, "copied": False})
        deliver_to_clipboard(saved)
        return True, saved


def deliver_to_clipboard(saved):
    """Shared from someone's clipboard -> it goes on ours. Text and images live only on the
    clipboard (the temp file is removed); copied files stay in the folder and the clipboard
    gets references to them, so Cmd+V in Finder pastes them."""
    kinds = {s["clipboard"] for s in saved if s["clipboard"]}
    if len(kinds) != 1:
        return
    kind = kinds.pop()
    if kind in ("text", "image") and len(saved) == 1:
        s = saved[0]
        if kind == "text":
            s["preview"] = preview_text(s["path"])
        if set_clipboard(kind, [s["path"]]):
            os.remove(s["path"])
            s["path"], s["copied"] = None, True
    elif kind == "files":
        if set_clipboard("files", [s["path"] for s in saved]):
            for s in saved:
                s["copied"] = True


def print_received(sender, items):
    print(f"\nreceived from {sender}:")
    for it in items:
        speed = human(it["size"] / max(it["secs"], 1e-3))
        if it["clipboard"] == "text" and it["copied"]:
            print(f'  text copied to your clipboard: "{it.get("preview", "")}"')
        elif it["clipboard"] == "image" and it["copied"]:
            print(f"  image copied to your clipboard  ({human(it['size'])})")
        else:
            print(f"  {it['path']}  ({human(it['size'])}, {speed}/s)")
    if any(it["clipboard"] == "files" and it["copied"] for it in items):
        print("  (also on your clipboard -- paste with Cmd+V in Finder)")


def local_addresses():
    try:
        out = subprocess.run(["/sbin/ifconfig"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return {"127.0.0.1"}
    return {"127.0.0.1"} | {l.split()[1] for l in out.splitlines() if l.split()[:1] == ["inet"]}


class OfferListener:
    """Collects offer beacons from the network in a background thread."""

    def __init__(self, allow_self=True):
        self.allow_self = allow_self
        self.offers, self.lock, self.stop = {}, threading.Lock(), threading.Event()
        self.mine, self.mine_at = set(), 0.0
        threading.Thread(target=self._listen, daemon=True).start()

    def _is_mine(self, ip):
        if time.time() - self.mine_at > 10:   # follow Wi-Fi changes
            self.mine, self.mine_at = local_addresses(), time.time()
        return ip in self.mine

    def _listen(self):
        s = listen_socket()
        while not self.stop.is_set():
            try:
                data, (ip, _) = s.recvfrom(65536)
                msg = json.loads(data)
            except (socket.timeout, ValueError):
                continue
            except OSError:
                time.sleep(1)
                continue
            if not (isinstance(msg, dict) and msg.get("app") == "knockdrop" and msg.get("v") == 1 and "id" in msg):
                continue
            if not self.allow_self and self._is_mine(ip):
                continue   # our own `knockdrop send`
            with self.lock:
                self.offers[msg["id"]] = (msg, ip, time.time())

    def live(self):
        """[(beacon, ip)] for offers heard in the last few seconds."""
        with self.lock:
            now = time.time()
            for k in [k for k, (_, _, seen) in self.offers.items() if now - seen > OFFER_SEEN_TTL]:
                del self.offers[k]
            return [(m, ip) for m, ip, _ in self.offers.values()]

    def close(self):
        self.stop.set()


def offer_label(m):
    kind = m.get("clipboard")
    if kind == "text":
        return "clipboard text"
    if kind == "image":
        return "a clipboard image"
    n = len(m.get("files", []))
    return f"{n} file{'s' if n != 1 else ''}"


def cmd_receive(args, source):
    out_dir = os.path.abspath(os.path.expanduser(args.out))
    os.makedirs(out_dir, exist_ok=True)
    listener = OfferListener()

    if local_network_blocked():
        print("warning: " + LOCAL_NETWORK_HELP, flush=True)
    time.sleep(1.5)
    seen = listener.live()
    if seen:
        print("nearby offers: " + ", ".join(f"{m['from']} ({offer_label(m)}, {m['knocks']} knocks)" for m, _ in seen))
    else:
        print("no offers nearby yet -- they'll be picked up as soon as one appears")

    try:
        while True:
            pattern = args.pattern or capture_pattern(source, "\nknock the sender's rhythm...")
            print("  " + render(pattern))
            cands = [(m, ip) for m, ip in listener.live() if m["knocks"] == len(pattern)]
            if not cands:
                others = sorted({m["knocks"] for m, _ in listener.live()})
                hint = f" (offers nearby have {', '.join(map(str, others))} knocks)" if others else " (no offers nearby)"
                print(f"  no offer with {len(pattern)} knocks{hint}")
            for m, ip in cands:
                try:
                    ok, result = try_claim(m, ip, pattern, out_dir)
                except (OSError, ValueError, ConnectionError) as e:
                    print(f"  {m['from']}: {e}")
                    continue
                if ok:
                    print_received(m["from"], result)
                    if not args.stay:
                        return
                    break
                print(f"  {m['from']}: {result}")
            else:
                if args.pattern:
                    sys.exit(1)
                print("  try again")
    except KeyboardInterrupt:
        print()
    finally:
        listener.close()


# ---------------------------------------------------------------- agent (background receiver)

def cmd_agent(args):
    """Background receiver for the menu bar app. JSON events on stdout; commands on stdin
    ({"cmd": "pattern", "times": [...]} from the keyboard overlay, {"cmd": "keys", "on": bool}).

    Two ways to receive, for the same offer:
    - elsewhere: the sensor is off until someone nearby shares; then knock their rhythm.
    - same table (--table): the sensor stays on and remembers rhythms felt in the last
      TABLE_WINDOW seconds. When an offer appears with the same knock count right after, it
      was knocked on our table -- claim it with what we felt. No action needed."""
    enable_events()
    out_dir = os.path.abspath(os.path.expanduser(args.out))
    os.makedirs(out_dir, exist_ok=True)
    commands, cmd_lock = [], threading.Lock()

    def on_command(c):
        with cmd_lock:
            commands.append(c)

    read_parent_commands(on_command)
    has_sensor = args.pattern is None and sensor_available()
    emit("hello", version=__version__, out=out_dir, sensor=has_sensor,
         app_stale=os.path.isfile(MENUBAR_SRC) and menubar_app_stale())
    # KNOCKDROP_ALLOW_SELF=1: also take offers from this Mac (testing the app with one Mac)
    listener = OfferListener(allow_self=args.allow_self or os.environ.get("KNOCKDROP_ALLOW_SELF") == "1")
    if local_network_blocked():
        emit("error", message="Local Network access is blocked")

    src, knocks, keys_mode = None, [], False
    failed, scripted_done, last_status = {}, set(), None
    got, first_seen, table_tried, recent = set(), {}, set(), []   # recent: [(last knock time, pattern)]

    def claim(pattern, offers, via):
        n = len(pattern)
        if not MIN_KNOCKS <= n <= MAX_KNOCKS:
            emit("pattern", knocks=n, result="ignored", via=via)
            return
        cands = [(m, ip) for m, ip in offers if m["knocks"] == n]
        if not cands:
            emit("pattern", knocks=n, result="no_offer", via=via,
                 offer_knocks=sorted({m["knocks"] for m, _ in offers}))
            return
        for m, ip in cands:
            try:
                ok, result = try_claim(m, ip, pattern, out_dir)
            except (OSError, ValueError, ConnectionError) as e:
                emit("error", message=f"{m['from']}: {e}")
                continue
            if ok:
                got.add(m["id"])
                print_received(m["from"], result)
                emit("received", sender=m["from"], items=[
                    {k: it.get(k) for k in ("name", "size", "path", "clipboard", "copied", "preview")} for it in result])
                return
            failed[m["id"]] = failed.get(m["id"], 0) + 1
        emit("pattern", knocks=n, result="no_match", via=via)

    try:
        while True:
            offers = [(m, ip) for m, ip in listener.live()
                      if failed.get(m["id"], 0) < AGENT_MAX_TRIES and m["id"] not in got]
            now = time.monotonic()
            for m, _ in offers:
                first_seen.setdefault(m["id"], now)
            status = {"state": "listening" if offers else "idle", "table": bool(args.table),
                      "offers": [{"id": m["id"], "from": m.get("from", ip), "knocks": m["knocks"],
                                  "label": offer_label(m), "clipboard": m.get("clipboard")} for m, ip in offers]}
            if status != last_status:
                print(time.strftime("%H:%M:%S"), "nearby:",
                      ", ".join(f"{o['from']} ({o['label']}, {o['knocks']} knocks)" for o in status["offers"]) or "nothing",
                      flush=True)
                emit("status", **status)
                last_status = status

            with cmd_lock:
                pending, commands[:] = list(commands), []
            for c in pending:
                if c.get("cmd") == "keys":           # keyboard overlay open: ignore the sensor meanwhile
                    keys_mode, knocks = bool(c.get("on")), []
                elif c.get("cmd") == "felt" and isinstance(c.get("times"), list):   # tests: as if felt on the table
                    recent.append((time.monotonic(), [float(t) for t in c["times"]]))
                elif c.get("cmd") == "pattern" and isinstance(c.get("times"), list):
                    keys_mode, knocks = False, []
                    claim([float(t) for t in c["times"]], offers, "keys")
                    if src:
                        src.flush()

            if args.pattern is not None:              # scripted test: claim each new offer once
                for m, ip in offers:
                    if m["id"] not in scripted_done:
                        scripted_done.add(m["id"])
                        claim(args.pattern, [(m, ip)], "script")
                time.sleep(0.25)
                continue

            if args.table:                             # same-table auto-receive
                recent[:] = [(t, p) for t, p in recent if now - t < TABLE_WINDOW + 5]
                for m, ip in offers:
                    if m["id"] in table_tried:
                        continue
                    seen = first_seen[m["id"]]
                    felt = [p for t, p in recent if len(p) == m["knocks"] and seen - TABLE_WINDOW <= t <= seen + 1.0]
                    if felt:
                        table_tried.add(m["id"])
                        claim(felt[-1], [(m, ip)], "table")
                    elif now - seen > 4.0 and not knocks:   # nothing felt around then: not our table
                        table_tried.add(m["id"])

            want_sensor = has_sensor and (offers or args.table)
            if want_sensor and src is None:
                src = IMUKnocks(args.sensitivity)
                try:
                    src.start()
                except SensorSilent:
                    emit("error", message="The motion sensor isn't sending data")
                    src, has_sensor = None, False
                    continue
                knocks = []
                emit("ready")
            elif src is not None and not want_sensor and not knocks:
                src.stop()
                src = None

            if src is None:
                time.sleep(0.25)
                continue
            for k in src.poll():
                if keys_mode:
                    continue
                knocks.append(k)
                emit("knock", n=len(knocks))
            if knocks and time.monotonic() - knocks[-1] > PATTERN_END_QUIET:
                last, pattern, knocks = knocks[-1], [k - knocks[0] for k in knocks], []
                if args.table and MIN_KNOCKS <= len(pattern) <= MAX_KNOCKS:
                    recent.append((last, pattern))
                if offers:
                    claim(pattern, offers, "sensor")
                    table_tried.update(m["id"] for m, _ in offers)   # we knocked for these ourselves
                src.flush()
            time.sleep(0.005)
    finally:
        listener.close()
        if src:
            src.stop()


# ---------------------------------------------------------------- knock (tuning)

def cmd_knock(args, source):
    print("knock patterns; Ctrl+C to quit")
    last = None
    try:
        while True:
            p = capture_pattern(source, "\nknock...")
            print("  " + render(p))
            print("  intervals: " + " ".join(f"{x:.2f}" for x in intervals(p)))
            if last is not None:
                d = pattern_distance(last, p)
                verdict = "different knock count" if d is None else (
                    f"distance {d:.3f} -> {'MATCH' if patterns_match(last, p, args.tolerance) else 'no match'}")
                print(f"  vs previous: {verdict}")
            last = p
    except KeyboardInterrupt:
        print()


def sensor_available():
    try:
        from macimu import IMU
        return IMU.available()
    except Exception:   # Intel Macs / missing IOKit pieces
        return False


def self_command():
    """argv that re-runs this program (works for the script and the packaged binary)."""
    if getattr(sys, "frozen", False):
        return [sys.executable]
    return [sys.executable, os.path.abspath(__file__)]


def relaunch_with_sudo():
    print("the motion sensor needs root on this Mac -- asking for your password (sudo):", flush=True)
    os.execvp("sudo", ["sudo"] + self_command() + sys.argv[1:])


APP_PATH = os.path.expanduser("~/Applications/Knockdrop.app")
LOGIN_PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{APP_ID}.plist")
MENUBAR_SRC = os.path.join(HERE, "menubar", "Knockdrop.swift")


def launcher_command():
    """How the menu bar app should run us. The `knockdrop` launcher exports its own path, which
    for Homebrew is /opt/homebrew/bin/knockdrop -- stable across `brew upgrade`."""
    b = os.environ.get("KNOCKDROP_BIN")
    if b and os.path.isabs(b) and os.access(b, os.X_OK):
        return [b]
    return self_command()


def menubar_stamp():
    with open(MENUBAR_SRC, "rb") as f:
        return hashlib.sha256(f.read() + json.dumps(launcher_command()).encode()).hexdigest()


def menubar_app_stale():
    try:
        with open(os.path.join(APP_PATH, "Contents", "Resources", "build-stamp")) as f:
            return f.read() != menubar_stamp()
    except OSError:
        return os.path.isdir(APP_PATH)


def stop_menubar_app():
    exe = os.path.join(APP_PATH, "Contents", "MacOS", "Knockdrop")
    if subprocess.run(["/usr/bin/pkill", "-f", exe], capture_output=True).returncode == 0:
        time.sleep(1)


def build_menubar_app(force=False):
    """Compile menubar/Knockdrop.swift into ~/Applications/Knockdrop.app (only when it changed).
    The app is built on each Mac with the Command Line Tools' swiftc, so it needs no signing."""
    if not os.path.isfile(MENUBAR_SRC):
        sys.exit(f"menu bar app source not found: {MENUBAR_SRC}")
    stamp = menubar_stamp()
    if not force and not menubar_app_stale() and os.path.isdir(APP_PATH):
        return False
    swiftc = shutil.which("swiftc") or "/usr/bin/swiftc"
    print("building the menu bar app (takes up to a minute the first time)...", flush=True)
    tmp = APP_PATH + ".building"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(os.path.join(tmp, "Contents", "MacOS"))
    os.makedirs(os.path.join(tmp, "Contents", "Resources"))
    exe = os.path.join(tmp, "Contents", "MacOS", "Knockdrop")
    try:
        r = subprocess.run([swiftc, "-O", "-swift-version", "5", "-o", exe, MENUBAR_SRC])
    except OSError:
        r = None
    if r is None or r.returncode != 0:
        shutil.rmtree(tmp, ignore_errors=True)
        sys.exit("couldn't build the menu bar app -- it needs the Xcode Command Line Tools "
                 "(install them with: xcode-select --install)")
    info = {
        "CFBundleIdentifier": APP_ID, "CFBundleName": "Knockdrop", "CFBundleDisplayName": "Knockdrop",
        "CFBundleExecutable": "Knockdrop", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": __version__, "CFBundleVersion": __version__,
        "LSUIElement": True, "LSMinimumSystemVersion": "11.0", "NSHighResolutionCapable": True,
        "NSLocalNetworkUsageDescription": "Knockdrop finds people sharing nearby and receives "
                                          "what they share over your Wi-Fi.",
        "KDCommand": launcher_command(),
    }
    with open(os.path.join(tmp, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump(info, f)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", tmp], capture_output=True)
    with open(os.path.join(tmp, "Contents", "Resources", "build-stamp"), "w") as f:
        f.write(stamp)
    stop_menubar_app()
    shutil.rmtree(APP_PATH, ignore_errors=True)
    os.makedirs(os.path.dirname(APP_PATH), exist_ok=True)
    os.rename(tmp, APP_PATH)
    return True


def cmd_menubar(args):
    if args.remove:
        stop_menubar_app()
        for p in (LOGIN_PLIST,):
            if os.path.exists(p):
                os.remove(p)
        shutil.rmtree(APP_PATH, ignore_errors=True)
        print(f"removed the menu bar app ({APP_PATH}) and its login item")
        return
    build_menubar_app(force=args.rebuild)
    if args.build_only:
        print(APP_PATH)
        return
    subprocess.run(["/usr/bin/open", APP_PATH])
    print("knockdrop is in your menu bar (the hand icon).\n"
          "  when someone nearby shares, knock their rhythm on your laptop -- or press Ctrl+Option+K\n"
          "  and tap it on the space bar. Shared clipboards land on your clipboard; files in ~/Downloads.")


def cmd_check():
    ok = True
    print(f"knockdrop on {hostname()}")
    try:
        from macimu import IMU
        has = IMU.available()
        info = IMU.device_info() if has else {}
    except Exception as e:
        has, info = False, {"error": str(e)}
    sensors = ", ".join(info.get("sensors", [])) or info.get("error", "none")
    if has:
        print(f"  motion sensor: yes  ({sensors})")
    else:   # not a failure: knockdrop switches to space-bar taps on its own
        print("  motion sensor: none -- you'll tap the space bar instead")
    try:
        from multiprocessing import shared_memory
        shm = shared_memory.SharedMemory(create=True, size=4096)
        shm.close(); shm.unlink()
        print("  shared memory: ok")
    except Exception as e:
        print(f"  shared memory: FAILED ({e})"); ok = False
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("10.255.255.255", 1))
        ip = probe.getsockname()[0]
        probe.close()
        print(f"  network: {ip}")
    except OSError:
        print("  network: no LAN address -- connect to Wi-Fi"); ok = False
    try:
        listen_socket().close()
        print(f"  beacon port {BEACON_PORT}: ok")
    except OSError as e:
        print(f"  beacon port {BEACON_PORT}: FAILED ({e})"); ok = False
    if local_network_blocked():
        print("  local network access: BLOCKED -- " + LOCAL_NETWORK_HELP); ok = False
    else:
        print("  local network access: ok")
    print("ready" if ok else "not fully ready (see above)")


def add_knock_options(p, sub=False):
    """Knock options work before or after the subcommand (knockdrop --keys receive / knockdrop receive --keys).
    On subcommands they default to SUPPRESS so they don't overwrite a value given before the subcommand."""
    d = (lambda v: argparse.SUPPRESS) if sub else (lambda v: v)
    p.add_argument("--keys", action="store_true", default=d(False),
                   help="tap the space bar instead of knocking (automatic on Macs without the sensor)")
    p.add_argument("--sensitivity", type=float, default=d(2.5), metavar="N",
                   help="knock threshold in noise units; lower = more sensitive (default 2.5)")
    p.add_argument("--tolerance", type=float, default=d(0.12), metavar="F",
                   help="max rhythm difference, as a fraction of pattern length (default 0.12)")


def main():
    multiprocessing.freeze_support()
    ap = argparse.ArgumentParser(prog="knockdrop", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=f"knockdrop {__version__}")
    add_knock_options(ap)
    ap.add_argument("--pattern", type=lambda s: [float(x) for x in s.split(",")],
                    help=argparse.SUPPRESS)  # knock times in seconds, for scripted tests
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("send", help="offer files behind a knock rhythm")
    add_knock_options(s, sub=True)
    s.add_argument("files", nargs="*", metavar="FILE", help="files to share (default: what's on your clipboard)")
    s.add_argument("--events", action="store_true", help=argparse.SUPPRESS)   # JSON events, for the menu bar app
    s.add_argument("--multi", action="store_true", help="keep sharing after the first receiver")
    s.add_argument("-y", "--yes", action="store_true", help="don't ask to confirm the rhythm")
    r = sub.add_parser("receive", help="knock a rhythm to receive files")
    add_knock_options(r, sub=True)
    r.add_argument("--out", default=os.path.join("~" + os.environ.get("SUDO_USER", ""), "Downloads"),
                   metavar="DIR", help="where to save received files (default ~/Downloads)")
    r.add_argument("--stay", action="store_true", help="keep receiving after the first transfer")
    add_knock_options(sub.add_parser("knock", help="practice knocking and check that two rhythms match"), sub=True)
    sub.add_parser("check", help="check the sensor and network on this Mac")
    m = sub.add_parser("menubar", help="menu bar app: receive in the background by just knocking")
    m.add_argument("--remove", action="store_true", help="quit and remove the menu bar app and its login item")
    m.add_argument("--rebuild", action="store_true", help="rebuild the app even if it looks up to date")
    m.add_argument("--build-only", action="store_true", help=argparse.SUPPRESS)
    a = sub.add_parser("agent", help="background receiver used by the menu bar app (JSON events)")
    add_knock_options(a, sub=True)
    a.add_argument("--out", default="~/Downloads", metavar="DIR",
                   help="where to save received files (default ~/Downloads)")
    a.add_argument("--table", action="store_true",
                   help="same-table auto-receive: keep the sensor on and take offers knocked on this table")
    a.add_argument("--allow-self", action="store_true", help=argparse.SUPPRESS)  # accept our own offers (tests)
    args = ap.parse_args()

    if args.cmd == "check":
        return cmd_check()
    if args.cmd == "menubar":
        return cmd_menubar(args)
    if args.cmd == "agent":
        return cmd_agent(args)
    if getattr(args, "events", False):
        enable_events()
        read_parent_commands()
        if not args.pattern and not sensor_available():
            emit("error", message="No motion sensor on this Mac")
            sys.exit("no motion sensor")

    if args.pattern:
        source = None
        run = {"send": cmd_send, "receive": cmd_receive}.get(args.cmd)
        if run is None:
            sys.exit("--pattern only works with send/receive")
        return run(args, source)
    if not args.keys and not sensor_available():
        print("no motion sensor on this Mac -- tap the SPACE BAR instead of knocking", flush=True)
        args.keys = True
    source = KeyKnocks() if args.keys else IMUKnocks(args.sensitivity)
    with source:
        {"send": cmd_send, "receive": cmd_receive, "knock": cmd_knock}[args.cmd](args, source)


if __name__ == "__main__":
    main()
