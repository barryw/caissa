#!/usr/bin/env python3
"""Cycle-exact Colossus Chess 4 driver via the VICE (x64sc) remote text monitor.

This is the only honest way to measure our engine against Colossus: Colossus
runs unmodified inside x64sc, we read its committed replies off the board screen
($0400-$07E7) and feed it our engine's moves by poking the KERNAL keyboard
buffer. (The raw-6502 ColossusRawRunner backend corrupts Colossus's play -- it
answers checks with illegal moves -- so it must never be used as ground truth.)

Proven recipe (generalised from build/vice_boot_check.py):
  * Launch x64sc with -remotemonitor and autostart the "colossus 4.0-d" loader.
  * Connect to the remote monitor on TCP 127.0.0.1:6510. Emulation runs while
    no monitor command is pending; sending "x" resumes after a command burst.
  * Disable Colossus prediction: monitor `bank ram` then `> b49b 00`.
  * Enter a move by poking the KERNAL keyboard buffer at $0277:
      <rank-digit-ascii> <FILE-letter-UPPERCASE-ascii> 0d  (from square)
      <rank-digit-ascii> <FILE-letter-UPPERCASE-ascii> 0d  (to square)
    then set the buffer count $C6 = 6.
  * Poll the decoded board screen move list for the new ply.

The driver exposes a small surface used by run_colossus_match.py:
  ViceColossus.boot(), .disable_prediction(), .set_warp(), .read_screen(),
  .inject_move(uci), .wait_for_ply(target_ply, timeout) and the helpers
  screen_move_entries()/legalize_from_to() for parsing.
"""

from __future__ import annotations

import re
import socket
import subprocess
import time
from pathlib import Path
from typing import Any

HOST = "127.0.0.1"
PORT = 6510

# Move-list lines look like: "  1    e2-e4           d7-d5"
MOVE_LINE_RE = re.compile(
    r"^\s*(\d+)\s+([a-h][1-8])\s*[-x]\s*([a-h][1-8])"
    r"[+#]?(?:\s+([a-h][1-8])\s*[-x]\s*([a-h][1-8])[+#]?)?",
    re.IGNORECASE,
)


class ViceColossusError(RuntimeError):
    pass


def sc_to_ascii(b: int) -> str:
    """Decode a single C64 screen code byte to an ASCII char (uppercase fonts)."""
    b &= 0x7F
    if 1 <= b <= 26:
        return chr(ord("a") + b - 1)
    if 0x30 <= b <= 0x39:
        return chr(b)
    if b == 0x20:
        return " "
    if 0x41 <= b <= 0x5A:
        return chr(b - 0x41 + ord("A"))
    table = {
        0x2D: "-",
        0x2B: "+",
        0x2A: "*",
        0x3A: ":",
        0x3D: "=",
        0x28: "(",
        0x29: ")",
        0x2E: ".",
    }
    return table.get(b, ".")


def decode_screen_bytes(data: list[int]) -> str:
    return "\n".join(
        "".join(sc_to_ascii(v) for v in data[r : r + 40]).rstrip()
        for r in range(0, min(len(data), 1000), 40)
    )


def screen_move_entries(screen: str) -> list[tuple[int, str]]:
    """Parse the Colossus move list into (ply, "fromto") pairs (1-based ply)."""
    entries: list[tuple[int, str]] = []
    for line in screen.splitlines():
        match = MOVE_LINE_RE.match(line)
        if not match:
            continue
        move_number_text, white_from, white_to, black_from, black_to = match.groups()
        white_ply = (int(move_number_text) * 2) - 1
        entries.append((white_ply, (white_from + white_to).lower()))
        if black_from and black_to:
            entries.append((white_ply + 1, (black_from + black_to).lower()))
    return entries


def legalize_from_to(board: Any, move4: str, chess_module: Any) -> Any | None:
    """Match a 4-char from/to string to a legal move on the board (queen promo)."""
    from_square = chess_module.parse_square(move4[:2])
    to_square = chess_module.parse_square(move4[2:4])
    matches = [
        move
        for move in board.legal_moves
        if move.from_square == from_square and move.to_square == to_square
    ]
    if not matches:
        return None
    for move in matches:
        if move.promotion == chess_module.QUEEN:
            return move
    return matches[0]


class _Monitor:
    """Single-shot connection to the VICE remote text monitor.

    Each connection halts emulation on connect and resumes on close (via `x`),
    matching the proven build/vice_boot_check.py pattern. We open a fresh
    connection per burst of commands so emulation keeps running between reads.
    """

    def __init__(self, connect_timeout: float = 30.0, io_timeout: float = 30.0) -> None:
        last_exc: OSError | None = None
        deadline = time.monotonic() + connect_timeout
        while time.monotonic() < deadline:
            try:
                self.sock = socket.create_connection((HOST, PORT), timeout=io_timeout)
                break
            except OSError as exc:
                last_exc = exc
                time.sleep(1.0)
        else:
            raise ViceColossusError(f"could not reach VICE monitor at {HOST}:{PORT}: {last_exc}")
        self.sock.settimeout(io_timeout)
        self.buf = b""
        # A newline coaxes the (C:$....) prompt out.
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

    def close(self) -> None:
        try:
            # Resume emulation, then drop the socket.
            self.sock.sendall(b"x\n")
            time.sleep(0.05)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


class ViceColossus:
    """High-level driver around a running x64sc + Colossus Chess 4."""

    def __init__(
        self,
        d64: Path,
        program_entry: str = "colossus 4.0-d",
        x64sc: str = "/usr/local/bin/x64sc",
        warp_speed: int = 10000,
        connect_timeout: float = 30.0,
        io_timeout: float = 30.0,
    ) -> None:
        self.d64 = Path(d64)
        self.program_entry = program_entry
        self.x64sc = x64sc
        self.warp_speed = warp_speed
        self.connect_timeout = connect_timeout
        self.io_timeout = io_timeout
        self.proc: subprocess.Popen[bytes] | None = None
        self._owns_process = False

    # -- process lifecycle -------------------------------------------------

    def launch(self, boot_log: Path | None = None) -> None:
        """Spawn a fresh x64sc autostarting the Colossus loader entry."""
        autostart = f"{self.d64}:{self.program_entry}"
        command = [
            self.x64sc,
            "-default",
            "-remotemonitor",
            "-warp",
            "-console",
            "-autostart",
            autostart,
        ]
        log_handle = open(boot_log, "wb") if boot_log is not None else subprocess.DEVNULL
        self.proc = subprocess.Popen(
            command,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
        )
        self._owns_process = True
        self._wait_for_monitor_port()

    def _wait_for_monitor_port(self) -> None:
        deadline = time.monotonic() + self.connect_timeout
        while time.monotonic() < deadline:
            try:
                with socket.create_connection((HOST, PORT), timeout=2.0):
                    return
            except OSError:
                time.sleep(0.5)
        raise ViceColossusError(
            f"VICE monitor port {HOST}:{PORT} never opened within {self.connect_timeout:.0f}s"
        )

    def kill(self) -> None:
        if self.proc is not None and self._owns_process:
            try:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            except Exception:
                pass
            self.proc = None

    # -- monitor primitives ------------------------------------------------

    def _with_monitor(self, fn: Any) -> Any:
        monitor = _Monitor(connect_timeout=self.connect_timeout, io_timeout=self.io_timeout)
        try:
            return fn(monitor)
        finally:
            monitor.close()

    def read_screen(self) -> str:
        """Read $0400-$07E7 and decode to text (Colossus board + move list)."""

        def fn(monitor: _Monitor) -> str:
            text = monitor.cmd("m 0400 07e7")
            data: list[int] = []
            for line in text.splitlines():
                line = line.strip()
                if not line.startswith(">C:"):
                    continue
                for token in line[3:].split()[1:]:
                    if len(token) == 2 and all(c in "0123456789abcdefABCDEF" for c in token):
                        data.append(int(token, 16))
                    else:
                        break
            return decode_screen_bytes(data)

        return self._with_monitor(fn)

    def set_warp(self, speed: int | None = None) -> None:
        """Force warp mode on. VICE autostart can drop warp during loading."""
        speed = self.warp_speed if speed is None else speed

        def fn(monitor: _Monitor) -> None:
            # WarpMode is a runtime resource; set it via the monitor.
            monitor.cmd("warp on")

        # `warp on` is not universally supported across VICE builds; fall back
        # silently because launch already passes -warp on the command line.
        try:
            self._with_monitor(fn)
        except ViceColossusError:
            raise
        except Exception:
            pass

    def disable_prediction(self) -> None:
        """Disable Colossus opponent-move prediction ($B49B=0) to avoid desync."""

        def fn(monitor: _Monitor) -> None:
            monitor.cmd("bank ram")
            monitor.cmd("> b49b 00")

        self._with_monitor(fn)

    def inject_move(self, uci: str) -> str:
        """Feed a UCI move into the KERNAL keyboard buffer (from then to square).

        Colossus reads coordinate input as <rank><FILE><return> per square. We
        write the six bytes to $0277 and set the buffer length at $C6.
        """
        normalized = uci.strip().lower()
        if len(normalized) < 4:
            raise ValueError(f"expected a UCI-like move such as e2e4, got {uci!r}")
        f1, r1, f2, r2 = normalized[0], normalized[1], normalized[2], normalized[3]
        if f1 not in "abcdefgh" or f2 not in "abcdefgh":
            raise ValueError(f"move files must be a-h, got {uci!r}")
        if r1 not in "12345678" or r2 not in "12345678":
            raise ValueError(f"move ranks must be 1-8, got {uci!r}")
        seq = [ord(r1), ord(f1.upper()), 0x0D, ord(r2), ord(f2.upper()), 0x0D]

        def fn(monitor: _Monitor) -> None:
            monitor.cmd("bank cpu")
            monitor.cmd("> 0277 " + " ".join(f"{b:02x}" for b in seq))
            monitor.cmd(f"> c6 {len(seq):02x}")

        self._with_monitor(fn)
        return " ".join(f"{b:02x}" for b in seq)

    # -- boot / polling ----------------------------------------------------

    def wait_for_boot(self, timeout: float = 180.0, poll_seconds: float = 5.0) -> str:
        deadline = time.monotonic() + timeout
        last = ""
        while time.monotonic() < deadline:
            last = self.read_screen()
            if "COLOSSUS 4.0" in last.upper() and "LOADING" not in last.upper():
                return last
            time.sleep(poll_seconds)
        raise ViceColossusError(
            f"Colossus did not reach the board within {timeout:.0f}s\n{last}"
        )

    def wait_for_ply(
        self,
        target_ply: int,
        timeout: float,
        poll_seconds: float = 2.0,
        warp_refresh_seconds: float = 5.0,
    ) -> str:
        """Poll the move list until ply `target_ply` (1-based) appears."""
        deadline = time.monotonic() + timeout
        last_screen = ""
        last_visible: list[int] = []
        last_warp_refresh = 0.0
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now - last_warp_refresh > warp_refresh_seconds:
                self.set_warp()
                last_warp_refresh = now
            last_screen = self.read_screen()
            last_visible = [ply for ply, _ in screen_move_entries(last_screen)]
            if target_ply in last_visible:
                return last_screen
            time.sleep(poll_seconds)
        raise ViceColossusError(
            f"Colossus move list did not show ply {target_ply} within {timeout:.0f}s; "
            f"visible={last_visible}\n{last_screen}"
        )

    def __enter__(self) -> "ViceColossus":
        return self

    def __exit__(self, *exc: object) -> None:
        self.kill()
