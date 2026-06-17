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
            "-console",
            "-autostart", str(self.prg),
        ]
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

    def _read(self, mon: _Monitor, addr: int, n: int) -> list[int]:
        out = mon.cmd(f"m {addr:04x} {addr + n - 1:04x}")
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
        if len(vals) < n:
            raise ViceCaissaError(f"short read at {addr:04x}: got {len(vals)}/{n}")
        return vals[:n]

    def _u16(self, lo_hi: list[int]) -> int:
        v = lo_hi[0] | (lo_hi[1] << 8)
        return v - 0x10000 if v >= 0x8000 else v  # signed

    def _u32(self, b: list[int]) -> int:
        return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)

    # -- high-level peek/poke ----------------------------------------------

    def _reconnect(self) -> None:
        """Drop the monitor socket so the next op opens a fresh one.

        VICE's monitor listener can desync after a long idle (e.g. while the
        opponent thinks for minutes and our socket sits unused); -keepmonopen
        keeps the listener alive, so a fresh connect recovers. The 6502 keeps
        running the whole time, so server RAM state is intact across reconnects.
        """
        if self._monitor is not None:
            try:
                self._monitor.close()
            except OSError:
                pass
            self._monitor = None

    def _op(self, fn, attempts: int = 5):
        """Run fn(mon) inside a synced monitor (bank ram), with resume after.

        On any monitor failure (short read, lost prompt, dropped socket) drop
        the connection, reconnect, and retry -- the running CPU is unaffected.
        """
        last: Exception | None = None
        for i in range(attempts):
            mon = self.monitor
            try:
                mon.sync_prompt()
                mon.cmd("bank ram")
                result = fn(mon)
                mon.resume()
                return result
            except (ViceCaissaError, OSError) as exc:
                last = exc
                self._reconnect()
                time.sleep(0.3 + 0.2 * i)
        raise ViceCaissaError(f"monitor op failed after {attempts} attempts: {last}")

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
                 poll: float = 0.3) -> dict:
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
