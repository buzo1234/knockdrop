#!/usr/bin/env python3
"""End-to-end tests on one Mac: real sockets, real clipboard, scripted knocks (no sensor needed).

    /usr/bin/python3 tests/e2e_local.py

Your clipboard is saved first and restored at the end. Needs Local Network access for the terminal.
"""
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import knockdrop as kd  # noqa: E402

KD = [os.path.join(ROOT, "knockdrop")]
P = [0, 0.4, 0.6, 1.4, 1.8]            # the sender's rhythm
P_SAME = [0, 0.42, 0.63, 1.45, 1.86]   # same rhythm, a bit slower and sloppier
P_OTHER = [0, 0.8, 1.0, 1.2, 1.8]      # same knock count, different rhythm
csv = lambda p: ",".join(map(str, p))

failures = []


def check(name, ok, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {name}" + (f"  -- {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


class Proc:
    """A knockdrop process whose JSON events we can wait for."""

    def __init__(self, args, events=True):
        self.p = subprocess.Popen(KD + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        self.q = queue.Queue()
        self.events = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            self.events.append(e)
            self.q.put(e)

    def wait(self, event, timeout=15, where=lambda e: True):
        end = time.time() + timeout
        while time.time() < end:
            try:
                e = self.q.get(timeout=max(0.05, end - time.time()))
            except queue.Empty:
                break
            if e.get("event") == event and where(e):
                return e
        return None

    def cmd(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def stop(self):
        if self.p.poll() is None:
            self.p.terminate()
            try:
                self.p.wait(5)
            except subprocess.TimeoutExpired:
                self.p.kill()


def share(args, pattern=P):
    """Start a multi-receiver offer and wait until it's announced."""
    s = Proc(["--pattern", csv(pattern), "send", "--events", "--multi"] + args)
    assert s.wait("waiting"), "sender never started waiting: " + s.p.stderr.read()
    time.sleep(1.2)   # first beacons out
    return s


def clipboard():
    d = tempfile.mkdtemp(dir=TMP)
    return kd.read_clipboard(d)


def set_text(t):
    f = os.path.join(TMP, "set.txt")
    with open(f, "w", encoding="utf-8") as fh:
        fh.write(t)
    assert kd.set_clipboard("text", [f])


TMP = tempfile.mkdtemp(prefix="knockdrop-e2e-")
OUT = os.path.join(TMP, "out")
os.makedirs(OUT)
SAVE = os.path.join(TMP, "saved-clipboard")
os.makedirs(SAVE)
saved = kd.read_clipboard(SAVE)
procs = []
try:
    print("clipboard text -> background receiver -> receiver's clipboard")
    set_text("secret-123 👊 héllo")
    s = share([]); procs.append(s)
    set_text("something else")
    a = Proc(["--pattern", csv(P_SAME), "agent", "--allow-self", "--out", OUT]); procs.append(a)
    r = a.wait("received")
    item = (r or {}).get("items", [{}])[0]
    check("received event", r is not None, a.p.stderr.read() if r is None else "")
    check("marked as copied text", item.get("clipboard") == "text" and item.get("copied") is True, str(item))
    c = clipboard()
    got = open(c["path"], encoding="utf-8").read() if c.get("kind") == "text" else None
    check("receiver clipboard has the text", got == "secret-123 👊 héllo", repr(got))
    check("no stray file in the out folder", os.listdir(OUT) == [], str(os.listdir(OUT)))
    check("sender reported the transfer", s.wait("sent", 5) is not None)
    a.stop(); s.stop()

    print("clipboard image -> receiver's clipboard")
    png = os.path.join(TMP, "img.png")
    subprocess.run(["/usr/bin/sips", "-s", "format", "png", "-z", "64", "64",
                    "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns",
                    "--out", png], capture_output=True)
    assert kd.set_clipboard("image", [png])
    s = share([]); procs.append(s)
    set_text("not an image")
    a = Proc(["--pattern", csv(P_SAME), "agent", "--allow-self", "--out", OUT]); procs.append(a)
    r = a.wait("received")
    check("received an image", r is not None and r["items"][0].get("clipboard") == "image", str(r))
    check("receiver clipboard has an image", clipboard().get("kind") == "image")
    a.stop(); s.stop()

    print("files copied in Finder -> saved + on the receiver's clipboard")
    f1, f2 = os.path.join(TMP, "notes one.txt"), os.path.join(TMP, "two.txt")
    for f in (f1, f2):
        with open(f, "w") as fh:
            fh.write("contents of " + os.path.basename(f))
    assert kd.set_clipboard("files", [f1, f2])
    s = share([]); procs.append(s)
    set_text("not files")
    a = Proc(["--pattern", csv(P_SAME), "agent", "--allow-self", "--out", OUT]); procs.append(a)
    r = a.wait("received")
    names = sorted(os.listdir(OUT))
    check("both files saved", names == ["notes one.txt", "two.txt"], str(names))
    c = clipboard()
    check("clipboard points at the received copies",
          c.get("kind") == "files" and sorted(map(os.path.realpath, c["paths"])) ==
          sorted(os.path.realpath(os.path.join(OUT, n)) for n in names),
          str(c))
    a.stop(); s.stop()
    shutil.rmtree(OUT); os.makedirs(OUT)

    print("same table: rhythm felt just before the offer appears -> received with no action")
    doc = os.path.join(TMP, "deck.pdf")
    with open(doc, "wb") as fh:
        fh.write(os.urandom(300_000))
    a = Proc(["agent", "--allow-self", "--table", "--out", OUT]); procs.append(a)
    a.wait("hello")
    a.cmd({"cmd": "felt", "times": P_SAME})      # as if the laptop felt the sender's knocks on the table
    s = share([doc]); procs.append(s)
    r = a.wait("received", 10)
    check("auto-received from the table", r is not None and os.path.exists(os.path.join(OUT, "deck.pdf")),
          str([e for e in a.events if e["event"] != "status"]))
    check("file intact", r is not None and kd.file_digest(os.path.join(OUT, "deck.pdf")) == kd.file_digest(doc))
    s.stop()

    print("same table, different rhythm felt -> not received; then knock (keyboard) -> received")
    shutil.rmtree(OUT); os.makedirs(OUT)
    a.cmd({"cmd": "felt", "times": P_OTHER})
    s = share([doc]); procs.append(s)
    miss = a.wait("pattern", 10, where=lambda e: e.get("via") == "table")
    check("table claim rejected", miss is not None and miss.get("result") == "no_match", str(miss))
    check("nothing saved", os.listdir(OUT) == [])
    a.cmd({"cmd": "keys", "on": True})
    a.cmd({"cmd": "pattern", "times": P_SAME})
    r = a.wait("received", 10)
    check("received after knocking the rhythm", r is not None and os.listdir(OUT) == ["deck.pdf"], str(os.listdir(OUT)))
    a.stop(); s.stop()

    print("own offers are ignored by the background receiver")
    s = share([doc]); procs.append(s)
    a = Proc(["agent", "--out", OUT]); procs.append(a)
    st = a.wait("status", 5)
    time.sleep(2.5)
    sts = [e for e in a.events if e["event"] == "status"]
    check("no offers listed", all(not e["offers"] for e in sts), str(sts))
    a.stop(); s.stop()

    print("terminal `knockdrop receive` also puts clipboard text on the clipboard")
    set_text("from the terminal ✓")
    s = share([]); procs.append(s)
    set_text("overwritten")
    rcv = subprocess.run(KD + ["--pattern", csv(P_SAME), "receive", "--out", OUT], capture_output=True, text=True,
                         timeout=30)
    c = clipboard()
    got = open(c["path"], encoding="utf-8").read() if c.get("kind") == "text" else None
    check("clipboard has the text", got == "from the terminal ✓", repr(got) + rcv.stdout + rcv.stderr)
    check("receive output says so", "copied to your clipboard" in rcv.stdout, rcv.stdout)
    s.stop()
finally:
    for p in procs:
        p.stop()
    if saved.get("kind") in kd.CLIPBOARD_KINDS:
        kd.set_clipboard(saved["kind"], saved["paths"] if saved["kind"] == "files" else [saved["path"]])
    shutil.rmtree(TMP, ignore_errors=True)

print(f"\n{'all passed' if not failures else str(len(failures)) + ' FAILED: ' + ', '.join(failures)}")
sys.exit(1 if failures else 0)
