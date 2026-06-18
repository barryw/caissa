#!/usr/bin/env python3
"""Differential trace: VICE (ground truth) vs the fast core, from the SAME
Colossus ready-state snapshot, to find the first divergent instruction.

Both sides: load build/colossus_extract/runtime/ready.ram.bin into RAM, force
$01=$37, set the ready registers, pre-poke one keystroke ('2'), then single-step.
VICE is correct 6502 + correct C64 I/O by construction; the first instruction
where the fast core's PC/regs differ from VICE's is the bug (a CPU edge or a wrong
I/O read value).

  tools/fastcolossus/vice_diff.py [N=700]
"""
from __future__ import annotations
import re, socket, subprocess, sys, time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
def _find_x64sc():
    import os
    cands = [os.environ.get("X64SC"),
             str(Path.home() / "Git" / "vice-macos" / "vice" / "src" / "x64sc"),
             "/usr/local/bin/x64sc",
             "/Applications/x64sc.app/Contents/MacOS/x64sc"]
    for c in cands:
        if c and Path(c).exists():
            return c
    raise SystemExit("no x64sc found (set X64SC=...)")
X64SC = _find_x64sc()
SNAP = REPO / "build" / "colossus_extract" / "runtime" / "ready.ram.bin"
FASTCORE = Path(__file__).resolve().parent / "fastcolossus"
HOST, PORT = "127.0.0.1", 6510


class Mon:
    def __init__(self, port):
        self.s = socket.create_connection((HOST, port), timeout=30)
        self.s.settimeout(20)
        self.buf = b""
        self.s.sendall(b"\n"); self.prompt()

    def prompt(self, timeout=20):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if b"(C:$" in self.buf and self.buf.rstrip().endswith(b")"):
                out, self.buf = self.buf, b""
                return out.decode("latin1", "replace")
            try:
                ch = self.s.recv(65536)
            except socket.timeout:
                break
            if not ch:
                break
            self.buf += ch
        out, self.buf = self.buf, b""
        return out.decode("latin1", "replace")

    def cmd(self, line, timeout=20):
        self.s.sendall(line.encode("latin1") + b"\n")
        return self.prompt(timeout)


# VICE step/register line: ".C:e5cf  85 CC  STA $CC  - A:00 X:00 Y:0A SP:f3 ..-...Z. 102657883"
LINE = re.compile(
    r"\.?C:([0-9a-f]{4}).*?A:([0-9a-f]{2})\s+X:([0-9a-f]{2})\s+Y:([0-9a-f]{2})\s+SP:([0-9a-f]{2})\s+([-.NVBDIZC#]{8})",
    re.I)


def flags_to_byte(fl: str) -> int:
    # order NV-BDIZC; letter set, '.' clear; pos2 is the unused/break marker.
    bits = [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01]
    p = 0x20  # unused always set
    for i, ch in enumerate(fl):
        if i == 2:
            continue
        if ch not in ".-":
            p |= bits[i]
    return p


def parse_state(text: str):
    for line in reversed(text.splitlines()):
        m = LINE.search(line)
        if m:
            pc, a, x, y, sp, fl = m.groups()
            return (int(pc, 16), int(a, 16), int(x, 16), int(y, 16), int(sp, 16),
                    flags_to_byte(fl))
    return None


def vice_trace(n: int) -> list[tuple]:
    subprocess.run(["pkill", "-f", "x64sc"], check=False)
    time.sleep(1)
    proc = subprocess.Popen(
        [X64SC, "-default", "-remotemonitor", "-remotemonitoraddress",
         f"ip4://{HOST}:{PORT}", "-keepmonopen", "-warp", "+sound", "-console"],
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                Mon(PORT).s.close(); break
            except OSError:
                time.sleep(0.5)
        m = Mon(PORT)
        m.cmd("bank ram")
        m.cmd(f'bload "{SNAP}" 0 0000')
        m.cmd("> 0000 2f")        # DDR
        m.cmd("> 0001 37")        # banking: KERNAL+BASIC+I/O
        m.cmd("> 0277 32")        # keyboard buffer: '2'
        m.cmd("> 00c6 01")        # buffer length 1
        m.cmd("r pc=f155")
        m.cmd("r sp=f5")
        m.cmd("r a=00"); m.cmd("r x=00"); m.cmd("r y=00")
        m.cmd("r fl=23")   # C=1 Z=1 (matches the fast core's initial P)
        states = []
        for i in range(n):
            out = m.cmd("z")       # step one instruction
            st = parse_state(out)
            if st is None:
                print(f"[vice] parse fail at step {i}:\n{out}", file=sys.stderr)
                break
            states.append((i,) + st)
        m.cmd("x")
        return states
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()


def fast_trace(n: int) -> list[tuple]:
    import os
    env = dict(os.environ, FCHASH=str(n), FCEMIT="1")
    out = subprocess.run([str(FASTCORE)], cwd=str(REPO), env=env,
                         capture_output=True, text=True).stdout
    states = []
    for line in out.splitlines():
        m = re.match(r"I=(\d+) PC=([0-9A-F]{4}) A=([0-9A-F]{2}) X=([0-9A-F]{2}) "
                     r"Y=([0-9A-F]{2}) SP=([0-9A-F]{2}) P=([0-9A-F]{2})", line)
        if m:
            g = m.groups()
            states.append((int(g[0]), int(g[1], 16), int(g[2], 16), int(g[3], 16),
                           int(g[4], 16), int(g[5], 16), int(g[6], 16)))
    return states


def main(argv):
    n = int(argv[0]) if argv else 700
    print(f"tracing {n} instructions on VICE (ground truth) ...")
    vraw = vice_trace(n)
    print(f"  got {len(vraw)} VICE states")
    fr = fast_trace(n)
    print(f"  got {len(fr)} fast-core states")
    # VICE `z` reports state AFTER the step; realign to "before instr i" by
    # prepending the known initial state (matches fast[0]).
    vb = [(0xF155, 0, 0, 0, 0xF5, 0x23)]
    vb += [(s[1], s[2], s[3], s[4], s[5], s[6]) for s in vraw[:-1]]
    fb = [(s[1], s[2], s[3], s[4], s[5], s[6]) for s in fr]
    for i in range(min(len(vb), len(fb))):
        v, f = vb[i], fb[i]
        vmask = (v[0], v[1], v[2], v[3], v[4], v[5] & 0xCF)
        fmask = (f[0], f[1], f[2], f[3], f[4], f[5] & 0xCF)
        if vmask != fmask:
            print(f"\n*** FIRST DIVERGENCE before instruction {i} ***")
            print("     idx  VICE (truth)                       FAST core")
            for k in range(max(0, i - 5), min(i + 2, len(vb), len(fb))):
                v2, f2 = vb[k], fb[k]
                mark = " <== DIVERGE" if k == i else ""
                print(f"  {k:5d}  PC={v2[0]:04X} A={v2[1]:02X} X={v2[2]:02X} Y={v2[3]:02X} SP={v2[4]:02X} P={v2[5]:02X}"
                      f"   PC={f2[0]:04X} A={f2[1]:02X} X={f2[2]:02X} Y={f2[3]:02X} SP={f2[4]:02X} P={f2[5]:02X}{mark}")
            print(f"\n=> the instruction at PC={vb[i-1][0]:04X} (instr {i-1}) produced the divergence")
            return 0
    print(f"\nNo divergence in {min(len(vb), len(fb))} instructions (extend N).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
