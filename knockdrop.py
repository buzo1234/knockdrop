#!/usr/bin/env python3
"""knockdrop -- share files between Macs on the same Wi-Fi by knocking the same rhythm.

    ./knockdrop send FILE [FILE ...]     knock a rhythm, wait for someone to repeat it
    ./knockdrop receive                  knock the sender's rhythm to get the files
    ./knockdrop knock                    just print detected knock patterns (tuning)
    ./knockdrop check                    check the sensor and network on this Mac

Knocks are read from the motion sensor (accelerometer + gyroscope). Macs without
it (M1, Intel) automatically use the space bar instead; --keys forces that.
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
import struct
import subprocess
import sys
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


# ---------------------------------------------------------------- knock detection

class KnockDetector:
    """Streaming knock detector over 6-channel IMU samples (accel g, gyro deg/s).

    Each channel is high-passed with a slow EMA baseline and z-scored against
    noise measured during calibration. A knock is the moment the combined
    z-energy crosses `threshold`; it re-arms only after energy settles below
    threshold/2 for `settle` seconds and at least `refractory` seconds passed.
    """

    def __init__(self, threshold=10.0, refractory=0.09, settle=0.03, baseline_s=0.2, rate=800.0):
        self.threshold = threshold
        self.refractory = refractory
        self.settle = settle
        self.alpha = 1.0 / (baseline_s * rate)
        self.base = None
        self.noise = None
        self._calib = []
        self.armed = True
        self.last_knock = -1e9
        self.quiet_since = None

    def _highpass(self, v):
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
        cols = list(zip(*self._calib[len(self._calib) // 4:])) or [[0.0]] * 6
        floors = [5e-4] * 3 + [0.05] * 3
        self.noise = []
        for c, floor in zip(cols, floors):
            s = sorted(abs(x) for x in c)
            mad = s[len(s) // 2] if s else 0.0
            self.noise.append(max(1.4826 * mad, floor))
        self._calib = []

    def feed(self, t, v):
        """Feed one sample; return the knock time if this sample starts a knock."""
        hp = self._highpass(v)
        e = math.sqrt(sum((x / n) ** 2 for x, n in zip(hp, self.noise)) / len(hp))
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


class IMUKnocks:
    """Yields knock times from the built-in motion sensor."""

    def __init__(self, threshold):
        from macimu import IMU
        self.imu = IMU(decimation=1)
        self.det = KnockDetector(threshold=threshold)
        self._acc, self._gyr = [], []

    def __enter__(self):
        self.imu.start()
        print("calibrating -- keep hands off the laptop for a second...", flush=True)
        time.sleep(0.3)
        self._drain()
        end, n = time.time() + 1.2, 0
        while time.time() < end:
            for t, v in self._pairs():
                self.det.calibrate_feed(v)
                n += 1
            time.sleep(0.005)
        if n < 100:   # sensor didn't stream: this macOS wants root for it
            self.imu.stop()
            if os.geteuid() != 0:
                relaunch_with_sudo()
            sys.exit("the motion sensor isn't sending data -- use --keys to tap the space bar instead")
        self.det.finish_calibration()
        return self

    def __exit__(self, *exc):
        self.imu.stop()

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
    knocks = []
    while True:
        new = source.poll()
        for k in new:
            knocks.append(k)
            print("  knock" + (" " * 2) + str(len(knocks)), flush=True)
        if knocks and time.monotonic() - knocks[-1] > PATTERN_END_QUIET:
            if len(knocks) < MIN_KNOCKS:
                print(f"  only {len(knocks)} knock(s) -- need at least {MIN_KNOCKS}. again:", flush=True)
                knocks = []
                continue
            if len(knocks) > MAX_KNOCKS:
                print(f"  {len(knocks)} knocks -- max is {MAX_KNOCKS}. again:", flush=True)
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


# ---------------------------------------------------------------- send

class Offer:
    def __init__(self, paths, pattern, tolerance, multi):
        self.id = secrets.token_hex(8)
        self.pattern = pattern
        self.tolerance = tolerance
        self.multi = multi
        self.files = [{"name": os.path.basename(p), "size": os.path.getsize(p),
                       "sha256": file_digest(p), "path": p} for p in paths]
        self.failed = 0
        self.done = threading.Event()      # stop accepting / beaconing
        self.claimed = threading.Event()   # single-receiver mode: a transfer is in progress
        self.lock = threading.Lock()
        self.expires = time.time() + OFFER_LIFETIME

    def beacon(self, port):
        return {"app": "knockdrop", "v": 1, "id": self.id, "from": hostname(), "port": port,
                "knocks": len(self.pattern),
                "files": [{"name": f["name"], "size": f["size"]} for f in self.files]}


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
                send_json(conn, {"ok": False, "reason": "rhythm doesn't match"})
                if left <= 0:
                    print("too many wrong attempts -- closing the offer", flush=True)
                    offer.done.set()
                return
            if not offer.multi:
                offer.claimed.set()
        print(f"  {who} ({addr[0]}) matched -- sending...", flush=True)
        send_json(conn, {"ok": True, "from": hostname(),
                         "files": [{k: f_[k] for k in ("name", "size", "sha256")} for f_ in offer.files]})
        try:
            for item in offer.files:
                with open(item["path"], "rb") as src:
                    for chunk in iter(lambda: src.read(CHUNK), b""):
                        conn.sendall(chunk)
            conn.shutdown(socket.SHUT_WR)
            conn.recv(1)  # wait for the receiver to close
            print(f"  sent to {who}", flush=True)
            if not offer.multi:
                offer.done.set()
        except OSError as e:
            print(f"  transfer to {who} failed: {e} -- still waiting", flush=True)
            offer.claimed.clear()   # let them retry


def cmd_send(args, source):
    paths = [os.path.abspath(os.path.expanduser(p)) for p in args.files]
    for p in paths:
        if not os.path.isfile(p):
            sys.exit(f"not a file: {p}")
    total = sum(os.path.getsize(p) for p in paths)
    print(f"sharing {len(paths)} file(s), {human(total)}")

    while True:
        pattern = args.pattern or capture_pattern(source, "\nknock your secret rhythm on the laptop...")
        print("  " + render(pattern))
        if is_too_regular(pattern):
            print("  tip: evenly spaced knocks are easy to guess -- mix short and long gaps")
        if args.pattern or args.yes:
            break
        ans = input("  share with this rhythm? [Enter = yes / r = redo] ").strip().lower()
        if ans != "r":
            break

    offer = Offer(paths, pattern, args.tolerance, args.multi)
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
                warned = True
            rounds += 1
            if rounds % 10 == 0:
                dests = beacon_destinations()   # follow Wi-Fi changes
            offer.done.wait(BEACON_EVERY)
    threading.Thread(target=beacons, daemon=True).start()

    print(f"\nwaiting for someone on this Wi-Fi to knock the same rhythm "
          f"(expires in {OFFER_LIFETIME // 60} min, Ctrl+C to cancel)", flush=True)
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
            saved.append((dest, item["size"], time.time() - t0))
        return True, saved


def cmd_receive(args, source):
    out_dir = os.path.abspath(os.path.expanduser(args.out))
    os.makedirs(out_dir, exist_ok=True)
    offers, lock = {}, threading.Lock()
    stop = threading.Event()

    def listen():
        s = listen_socket()
        while not stop.is_set():
            try:
                data, (ip, _) = s.recvfrom(65536)
                msg = json.loads(data)
            except (socket.timeout, ValueError):
                continue
            if msg.get("app") == "knockdrop" and msg.get("v") == 1 and "id" in msg:
                with lock:
                    offers[msg["id"]] = (msg, ip, time.time())
    threading.Thread(target=listen, daemon=True).start()

    def live():
        with lock:
            now = time.time()
            for k in [k for k, (_, _, seen) in offers.items() if now - seen > OFFER_SEEN_TTL]:
                del offers[k]
            return list(offers.values())

    if local_network_blocked():
        print("warning: " + LOCAL_NETWORK_HELP, flush=True)
    time.sleep(1.5)
    seen = live()
    if seen:
        print("nearby offers: " + ", ".join(f"{m['from']} ({m['knocks']} knocks)" for m, _, _ in seen))
    else:
        print("no offers nearby yet -- they'll be picked up as soon as one appears")

    try:
        while True:
            pattern = args.pattern or capture_pattern(source, "\nknock the sender's rhythm...")
            print("  " + render(pattern))
            cands = [(m, ip) for m, ip, _ in live() if m["knocks"] == len(pattern)]
            if not cands:
                others = sorted({m["knocks"] for m, _, _ in live()})
                hint = f" (offers nearby have {', '.join(map(str, others))} knocks)" if others else " (no offers nearby)"
                print(f"  no offer with {len(pattern)} knocks{hint}")
            for m, ip in cands:
                try:
                    ok, result = try_claim(m, ip, pattern, out_dir)
                except (OSError, ValueError, ConnectionError) as e:
                    print(f"  {m['from']}: {e}")
                    continue
                if ok:
                    print(f"\nreceived from {m['from']}:")
                    for path, size, secs in result:
                        print(f"  {path}  ({human(size)}, {human(size / max(secs, 1e-3))}/s)")
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
        stop.set()


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
    print(f"  motion sensor: {'yes' if has else 'NO -- use --keys'}  ({sensors})")
    ok &= has
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


def main():
    multiprocessing.freeze_support()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=f"knockdrop {__version__}")
    ap.add_argument("--keys", action="store_true", help="tap the space bar instead of knocking")
    ap.add_argument("--sensitivity", type=float, default=10.0,
                    help="knock threshold in noise units; lower = more sensitive (default 10)")
    ap.add_argument("--tolerance", type=float, default=0.12,
                    help="max rhythm difference, as a fraction of pattern length (default 0.12)")
    ap.add_argument("--pattern", type=lambda s: [float(x) for x in s.split(",")],
                    help=argparse.SUPPRESS)  # knock times in seconds, for scripted tests
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("send", help="offer files behind a knock rhythm")
    s.add_argument("files", nargs="+")
    s.add_argument("--multi", action="store_true", help="keep sharing after the first receiver")
    s.add_argument("-y", "--yes", action="store_true", help="don't ask to confirm the rhythm")
    r = sub.add_parser("receive", help="knock a rhythm to receive files")
    r.add_argument("--out", default=os.path.join("~" + os.environ.get("SUDO_USER", ""), "Downloads"))
    r.add_argument("--stay", action="store_true", help="keep receiving after the first transfer")
    sub.add_parser("knock", help="print detected knock patterns (to tune sensitivity)")
    sub.add_parser("check", help="check the sensor and network on this Mac")
    args = ap.parse_args()

    if args.cmd == "check":
        return cmd_check()

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
