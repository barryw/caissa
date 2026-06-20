#!/usr/bin/env python3
"""Headless-VICE driver for the persistent Caissa bestmove server.

Boots build/caissa_server.prg inside x64sc, waits for the server's g_ready flag,
then serves bestmove requests by poking the FEN + depth into RAM and reading the
chosen move back -- all over the x64sc remote text monitor. RAM poke/peek is far
cleaner than Colossus's screen-scrape (tools/vice_colossus.py).

Mirrors vice_colossus.py's robust monitor handling (ONE persistent socket held
for the whole session, sync_prompt/resume to run the CPU between operations),
but is parameterised by monitor PORT: a Caissa-vs-Colossus match runs two x64sc
instances at once, each needing its own monitor, so the default port here (6511)
is deliberately NOT Colossus's 6510.

Standalone test (boots, serves one move, prints UCI):
    tools/vice_caissa.py bestmove "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" 4
    -> d2d4   (matches host `cref bestmove ... 4` and caissa_cli)
"""

from __future__ import annotations

import argparse
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

HOST = "127.0.0.1"
DEFAULT_PORT = 6511  # NOT 6510 -- leave that for a side-by-side Colossus monitor.
DEFAULT_X64SC = str(Path.home() / "Git" / "vice-macos" / "vice" / "src" / "x64sc")
REPO = Path(__file__).resolve().parents[1]
DEFAULT_PRG = REPO / "build" / "caissa_server.prg"

# 0x88 square + promo decode -- identical to tools/llvmmos_bench/caissa_cli.c.
PROMO_CHAR = {2: "n", 3: "b", 4: "r", 5: "q"}  # PT_KNIGHT..PT_QUEEN


class ViceCaissaError(RuntimeError):
    pass


def sq_to_uci(sq: int) -> str:
    return chr(ord("a") + (sq & 7)) + chr(ord("1") + (7 - (sq >> 4)))


def move_to_uci(frm: int, to: int, promo: int) -> str:
    uci = sq_to_uci(frm) + sq_to_uci(to)
    if promo in PROMO_CHAR:
        uci += PROMO_CHAR[promo]
    return uci


def parse_map(map_path: Path) -> dict[str, int]:
    """Pull ABI symbol -> address from the llvm-mos linker map.

    Map columns are: vma lma size align symbol  (vma is bare hex, no 0x). The
    symbol-only line (last token == name, first token hex) carries the address.
    """
    want = {
        "g_fen", "g_depth", "g_go", "g_done", "g_ready",
        "g_from", "g_to", "g_promo", "g_score", "g_nodes", "g_qnodes", "g_status",
    }
    addrs: dict[str, int] = {}
    line_re = re.compile(r"^\s*([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+\d+\s+\d+\s+(\S+)\s*$")
    for line in Path(map_path).read_text().splitlines():
        m = line_re.match(line)
        if not m:
            continue
        sym = m.group(2)
        if sym in want and sym not in addrs:
            addrs[sym] = int(m.group(1), 16)
    missing = want - set(addrs)
    if missing:
        raise ViceCaissaError(f"symbols not found in {map_path}: {sorted(missing)}")
    return addrs


class _Monitor:
    """Persistent connection to a VICE remote text monitor on (host, port).

    Copy of the proven pattern in vice_colossus._Monitor, parameterised by port.
    A command line halts the CPU and returns the ``(C:$....)`` prompt; ``x``
    resumes. Holding ONE socket open (resume with ``x`` between operations rather
    than reconnecting) is the fix for VICE's monitor-listener wedge under
    connect/close churn.
    """

    def __init__(self, host: str, port: int, connect_timeout: float = 30.0,
                 io_timeout: float = 30.0) -> None:
        self.host, self.port = host, port
        deadline = time.monotonic() + connect_timeout
        attempt = min(5.0, max(1.0, connect_timeout))
        last_exc: OSError | None = None
        while True:
            try:
                self.sock = socket.create_connection((host, port), timeout=attempt)
                break
            except OSError as exc:
                last_exc = exc
                if time.monotonic() >= deadline:
                    raise ViceCaissaError(
                        f"could not reach VICE monitor at {host}:{port}: {last_exc}")
                time.sleep(0.5)
        self.sock.settimeout(io_timeout)
        self.buf = b""
        self.sock.sendall(b"\n")
        self.wait_prompt()

    def wait_prompt(self, timeout: float = 30.0) -> str:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if b"(C:$" in self.buf and self.buf.rstrip().endswith(b")"):
                out, self.buf = self.buf, b""
                return out.decode("latin1", "replace")
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            self.buf += chunk
        out, self.buf = self.buf, b""
        return out.decode("latin1", "replace")

    def cmd(self, line: str, timeout: float = 30.0) -> str:
        self.sock.sendall(line.encode("latin1") + b"\n")
        return self.wait_prompt(timeout)

    def _drain(self, settle: float = 0.15) -> None:
        prev = self.sock.gettimeout()
        try:
            self.sock.settimeout(settle)
            while True:
                try:
                    chunk = self.sock.recv(65536)
                except (socket.timeout, OSError):
                    break
                if not chunk:
                    break
        finally:
            try:
                self.sock.settimeout(prev)
            except OSError:
                pass
        self.buf = b""

    def sync_prompt(self, timeout: float = 10.0) -> None:
        self._drain()
        self.sock.sendall(b"\n")
        out = self.wait_prompt(timeout)
        if "(C:$" not in out:
            raise OSError("VICE monitor prompt not reached (emulator gone?)")

    def resume(self) -> None:
        self.sock.sendall(b"x\n")
        self._drain()

    def close(self) -> None:
        try:
            self.sock.sendall(b"x\n")
            time.sleep(0.05)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


_HEX_BYTE = re.compile(r"\b([0-9a-fA-F]{2})\b")


class CaissaServer:
    """Drive a persistent caissa_server.prg inside headless x64sc."""

    def __init__(self, prg: Path = DEFAULT_PRG, map_path: Path | None = None,
                 x64sc: str = DEFAULT_X64SC, port: int = DEFAULT_PORT,
                 connect_timeout: float = 30.0, io_timeout: float = 30.0) -> None:
        self.prg = Path(prg)
        self.map_path = Path(map_path) if map_path else self.prg.with_suffix(".map")
        self.x64sc = x64sc
        self.port = port
        self.connect_timeout = connect_timeout
        self.io_timeout = io_timeout
        self.addrs = parse_map(self.map_path)
        self.proc: subprocess.Popen[bytes] | None = None
        self._monitor: _Monitor | None = None

    # -- lifecycle ---------------------------------------------------------

    def launch(self, boot_log: Path | None = None) -> None:
        if not self.prg.exists():
            raise ViceCaissaError(f"{self.prg} missing -- run tools/build_caissa_server.sh")
        try:
            (Path.home() / ".cache" / "vice" / "autostart-C64SC.d64").unlink()
        except OSError:
            pass
        command = [
            self.x64sc,
            "-default",
            "-remotemonitor",
            "-remotemonitoraddress", f"ip4://{HOST}:{self.port}",
            "-keepmonopen",
            "-jamaction", "1",
            "-warp",
            # Run flat out: -speed 0 lifts the 100% speed limit (the throttle
            # -warp alone doesn't override in the headless build); +sound /
            # -soundwarpmode 0 stop the SID from pacing emulation to audio rate.
            "-speed", "0",
            "+sound",
            "-soundwarpmode", "0",
            "-console",
        ]
        if os.environ.get("CAISSA_REU"):   # CREF_PROFILE_REU build: TT in the REU
            command += ["-reu", "-reusize", os.environ.get("CAISSA_REUSIZE", "512")]
            # CAISSA_REUIMAGE: preload REU RAM from an image (tools/build_reu_image.py)
            # so the EGTB tables are present at boot for the on-chip EGTB build.
            # +reuimagerw keeps the file read-only; emulated REU RAM stays writable
            # (the TT region of the image is zero and the search owns it).
            img = os.environ.get("CAISSA_REUIMAGE")
            if img:
                command += ["-reuimage", img, "+reuimagerw"]
        command += ["-autostart", str(self.prg)]
        log = open(boot_log, "wb") if boot_log else subprocess.DEVNULL
        self.proc = subprocess.Popen(
            command, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        self._wait_for_monitor_port()

    def _wait_for_monitor_port(self) -> None:
        deadline = time.monotonic() + max(60.0, self.connect_timeout)
        while time.monotonic() < deadline:
            try:
                with socket.create_connection((HOST, self.port), timeout=2.0):
                    return
            except OSError:
                if self.proc and self.proc.poll() is not None:
                    raise ViceCaissaError("x64sc exited before the monitor port opened")
                time.sleep(0.5)
        raise ViceCaissaError(f"monitor port {self.port} never opened")

    @property
    def monitor(self) -> _Monitor:
        if self._monitor is None:
            self._monitor = _Monitor(HOST, self.port, self.connect_timeout, self.io_timeout)
        return self._monitor

    # -- raw RAM access (monitor held + synced by caller) ------------------

    def _write(self, mon: _Monitor, addr: int, data: bytes) -> None:
        # 8 bytes per `>` line keeps lines short and the prompt responsive.
        for off in range(0, len(data), 8):
            chunk = data[off:off + 8]
            mon.cmd(f"> {addr + off:04x} " + " ".join(f"{b:02x}" for b in chunk))

    def _parse_mem(self, out: str) -> list[int]:
        vals: list[int] = []
        for line in out.splitlines():
            idx = line.find("C:")
            if idx < 0:
                continue
            # bytes follow the address token; the ascii gutter has no internal
            # spaces, so the first run of 2-hex tokens after the address is data.
            rest = line[idx + 2:]
            parts = rest.split(None, 1)
            if len(parts) < 2:
                continue
            vals.extend(int(h, 16) for h in _HEX_BYTE.findall(parts[1])[:16])
        return vals

    def _read(self, mon: _Monitor, addr: int, n: int) -> list[int]:
        # The monitor occasionally returns a partial/empty response (the `m`
        # reply races the prompt under warp). Re-drain and re-issue the SAME
        # command on the SAME socket -- NEVER reconnect for this (closing the
        # socket mid-burst wedges VICE's monitor listener; see vice_colossus).
        cmd = f"m {addr:04x} {addr + n - 1:04x}"
        for attempt in range(5):
            out = mon.cmd(cmd)
            vals = self._parse_mem(out)
            if len(vals) >= n:
                return vals[:n]
            mon._drain()
        raise ViceCaissaError(f"short read at {addr:04x}: got {len(vals)}/{n}")

    def _u16(self, lo_hi: list[int]) -> int:
        v = lo_hi[0] | (lo_hi[1] << 8)
        return v - 0x10000 if v >= 0x8000 else v  # signed

    def _u32(self, b: list[int]) -> int:
        return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)

    # -- high-level peek/poke ----------------------------------------------

    def _drop_monitor(self) -> None:
        """Discard the held connection with a BARE socket close.

        Mirrors vice_colossus._drop_monitor: do NOT send `x` (a write to a
        wedged/half-dead socket is what tips VICE's listener over). The 6502
        keeps running, so server RAM is intact for the fresh connection.
        """
        mon, self._monitor = self._monitor, None
        if mon is not None:
            try:
                mon.sock.close()
            except OSError:
                pass

    def _run_once(self, fn):
        mon = self.monitor
        try:
            mon.sync_prompt()      # re-enter cleanly on the held socket
            mon.cmd("bank ram")
            result = fn(mon)
        except Exception:
            self._drop_monitor()   # leave a known state for the retry path
            raise
        # Defensively re-assert warp on every resume (mirrors vice_colossus;
        # the -warp launch flag already holds here, so this is belt-and-braces).
        mon.cmd("warp on")
        mon.resume()               # keep the socket open for the next op
        return result

    def _op(self, fn):
        """Run fn(mon) on the held monitor; ONE bare-close reconnect on error.

        Held-socket-with-single-reconnect is the only pattern VICE's monitor
        tolerates (rapid close/reopen wedges the listener). Short reads are
        already retried inside _read on the same socket, so reaching the
        reconnect here means a genuinely sick socket.
        """
        try:
            return self._run_once(fn)
        except (ViceCaissaError, OSError):
            self._drop_monitor()
            time.sleep(0.5)
            return self._run_once(fn)

    def _peek(self, addr: int, n: int) -> list[int]:
        return self._op(lambda m: self._read(m, addr, n))

    def wait_ready(self, timeout: float = 60.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._peek(self.addrs["g_ready"], 1)[0] == 1:
                return
            if self.proc and self.proc.poll() is not None:
                raise ViceCaissaError("x64sc exited before the server became ready")
            time.sleep(0.5)
        raise ViceCaissaError("caissa server never set g_ready (boot/handshake failed)")

    def bestmove(self, fen: str, depth: int = 4, timeout: float = 180.0,
                 poll: float = 1.0) -> dict:
        a = self.addrs
        payload = fen.encode("ascii") + b"\x00"
        if len(payload) > 100:
            raise ViceCaissaError("FEN too long for g_fen[100]")

        def poke(m: _Monitor) -> None:
            self._write(m, a["g_fen"], payload)
            self._write(m, a["g_depth"], bytes([depth & 0xFF]))
            self._write(m, a["g_done"], b"\x00")
            self._write(m, a["g_go"], b"\x01")  # LAST: triggers the search
        self._op(poke)  # resumes -> the 6502 runs the search

        deadline = time.monotonic() + timeout
        while True:
            time.sleep(poll)
            if self._peek(a["g_done"], 1)[0] == 1:
                break
            if self.proc and self.proc.poll() is not None:
                raise ViceCaissaError("x64sc exited mid-search")
            if time.monotonic() > deadline:
                raise ViceCaissaError(f"search did not finish within {timeout}s")

        def read_results(m: _Monitor) -> dict:
            return {
                "status": self._read(m, a["g_status"], 1)[0],
                "from": self._read(m, a["g_from"], 1)[0],
                "to": self._read(m, a["g_to"], 1)[0],
                "promo": self._read(m, a["g_promo"], 1)[0],
                "score": self._u16(self._read(m, a["g_score"], 2)),
                "nodes": self._u32(self._read(m, a["g_nodes"], 4)),
                "qnodes": self._u32(self._read(m, a["g_qnodes"], 4)),
            }
        r = self._op(read_results)
        status = r["status"]
        frm, to, promo = r["from"], r["to"], r["promo"]
        score, nodes, qnodes = r["score"], r["nodes"], r["qnodes"]

        if status != 0:
            raise ViceCaissaError(f"server reported FEN parse error for: {fen}")
        return {
            "uci": move_to_uci(frm, to, promo),
            "from": frm, "to": to, "promo": promo,
            "score": score, "depth": depth, "nodes": nodes, "qnodes": qnodes,
        }

    def close(self) -> None:
        if self._monitor is not None:
            self._monitor.close()
            self._monitor = None
        if self.proc is not None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=10.0)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            self.proc = None

    def __enter__(self) -> "CaissaServer":
        self.launch()
        self.wait_ready()
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    bm = sub.add_parser("bestmove", help="boot the server, serve one move, print UCI")
    bm.add_argument("fen")
    bm.add_argument("depth", type=int, nargs="?", default=4)
    bm.add_argument("--prg", type=Path, default=DEFAULT_PRG)
    bm.add_argument("--port", type=int, default=DEFAULT_PORT)
    bm.add_argument("--x64sc", default=DEFAULT_X64SC)
    bm.add_argument("--timeout", type=float, default=180.0)
    bm.add_argument("--verbose", action="store_true")
    args = p.parse_args(argv)

    if args.cmd == "bestmove":
        srv = CaissaServer(prg=args.prg, port=args.port, x64sc=args.x64sc)
        t0 = time.monotonic()
        try:
            srv.launch()
            if args.verbose:
                print(f"[boot] monitor up on {HOST}:{args.port} "
                      f"({time.monotonic() - t0:.1f}s)", file=sys.stderr)
            srv.wait_ready()
            if args.verbose:
                print(f"[ready] g_ready=1 ({time.monotonic() - t0:.1f}s); ABI "
                      f"g_fen=0x{srv.addrs['g_fen']:x} go=0x{srv.addrs['g_go']:x}",
                      file=sys.stderr)
            res = srv.bestmove(args.fen, args.depth, timeout=args.timeout)
        finally:
            srv.close()
        if args.verbose:
            print(f"[done] {time.monotonic() - t0:.1f}s nodes={res['nodes']}",
                  file=sys.stderr)
        print(f"bestmove {res['uci']} score {res['score']} depth {res['depth']} "
              f"nodes {res['nodes']}")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
