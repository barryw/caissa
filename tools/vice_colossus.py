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
import threading
import time
from pathlib import Path
from typing import Any, Callable

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
    """Connection to the VICE remote text monitor.

    Sending a command line halts emulation and returns the ``(C:$....)``
    prompt; sending ``x`` resumes the CPU. The CPU runs while no command is
    pending, so a single connection can be HELD open for the whole game:
    issue a command -> read the prompt -> ``x`` to resume, leaving the socket
    open and idle between operations.

    This persistence is the fix for the production hang: opening and closing a
    fresh connection per operation drives VICE's monitor network layer into a
    ``vice_network_send: internal error`` loop that wedges the listener, after
    which new ``connect()`` calls time out ([Errno 60]). Holding one socket and
    resuming with ``x`` eliminates that churn.
    """

    def __init__(self, connect_timeout: float = 30.0, io_timeout: float = 30.0) -> None:
        last_exc: OSError | None = None
        deadline = time.monotonic() + connect_timeout
        # Use a short per-attempt connect timeout so a wedged/dead listener
        # surfaces quickly (a 30s SYN timeout was what masked the dead
        # emulator in production); retry until the overall deadline.
        attempt_timeout = min(5.0, max(1.0, connect_timeout))
        while True:
            try:
                self.sock = socket.create_connection((HOST, PORT), timeout=attempt_timeout)
                break
            except OSError as exc:
                last_exc = exc
                if time.monotonic() >= deadline:
                    raise ViceColossusError(
                        f"could not reach VICE monitor at {HOST}:{PORT}: {last_exc}"
                    )
                time.sleep(0.5)
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

    def _drain(self, settle: float = 0.15) -> None:
        """Read and discard whatever is currently buffered on the socket."""
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
        """Halt the CPU and reach a clean ``(C:$....)`` prompt before a burst.

        On a HELD connection the CPU is running (after a prior ``x``); a bare
        newline re-enters the monitor and yields a fresh prompt. We first drain
        any stale bytes so the next command's response is read cleanly -- this
        is what prevents the intermittent empty reads seen when reusing one
        socket across many operations.

        Raises OSError if the prompt is never reached (e.g. the emulator died
        and the socket is closed/reset) so the caller's recovery path engages
        instead of silently returning empty reads.
        """
        self._drain()
        try:
            self.sock.sendall(b"\n")
        except OSError:
            raise
        out = self.wait_prompt(timeout)
        if "(C:$" not in out:
            raise OSError("VICE monitor prompt not reached (emulator gone?)")

    def resume(self) -> None:
        """Resume emulation (`x`) but KEEP the socket open for reuse.

        The CPU runs after ``x``; the next operation calls sync_prompt() to
        re-enter the monitor cleanly, so here we only send ``x`` and drain its
        immediate echo.
        """
        self.sock.sendall(b"x\n")
        self._drain()

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


class _Heartbeat:
    """Background pinger that keeps the VICE monitor/emulator warm.

    Pings on a fixed interval in a daemon thread. Exceptions inside ping()
    are swallowed by ping() itself; the heartbeat never crashes the caller.
    """

    def __init__(self, vice: "ViceColossus", interval_seconds: float) -> None:
        self._vice = vice
        self._interval = max(1.0, interval_seconds)
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.pings = 0
        self.failures = 0

    def __enter__(self) -> "_Heartbeat":
        self._thread = threading.Thread(target=self._run, name="vice-heartbeat", daemon=True)
        self._thread.start()
        return self

    def _run(self) -> None:
        # First wait one interval so short operations cause no monitor traffic.
        while not self._stop.wait(self._interval):
            ok = self._vice.ping()
            self.pings += 1
            if not ok:
                self.failures += 1

    def __exit__(self, *exc: object) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=10.0)


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
        self._boot_log: Path | None = None
        # When set, _with_monitor will, on a dead/unreachable monitor, relaunch
        # x64sc and replay the game so far before retrying the operation. The
        # callback receives this driver and must restore identical board state
        # (boot Colossus, disable prediction, re-inject the engine moves).
        self.recovery_callback: Callable[["ViceColossus"], None] | None = None
        self._recovering = False
        # Boot config reused by wait_for_boot during relaunch.
        self.boot_timeout: float = 240.0
        self.boot_poll_seconds: float = 5.0
        # ONE persistent monitor connection for the whole game (the fix for the
        # connect/close-churn hang). Serialised by a lock so an optional
        # heartbeat thread can share it.
        self._monitor: _Monitor | None = None
        self._monitor_lock = threading.RLock()

    # -- process lifecycle -------------------------------------------------

    def launch(self, boot_log: Path | None = None) -> None:
        """Spawn a fresh x64sc autostarting the Colossus loader entry."""
        if boot_log is not None:
            self._boot_log = Path(boot_log)
        # Clear VICE's shared autostart cache so a relaunch never reuses a
        # stale cached program disk (causes the wrong/half program to boot).
        try:
            (Path.home() / ".cache" / "vice" / "autostart-C64SC.d64").unlink()
        except OSError:
            pass
        autostart = f"{self.d64}:{self.program_entry}"
        command = [
            self.x64sc,
            "-default",
            "-remotemonitor",
            # Keep the remote monitor listener open across client
            # disconnects; without this some VICE builds can tear the monitor
            # server down after a client drops, leaving the next connect to
            # hit a dead port (the production [Errno 60] symptom).
            "-keepmonopen",
            # On a CPU JAM, continue rather than the default "Ask" action,
            # which in -console mode blocks on stdin that never arrives and
            # wedges the emulator (monitor unreachable thereafter).
            "-jamaction",
            "1",
            "-warp",
            "-console",
            "-autostart",
            autostart,
        ]
        log_handle = (
            open(self._boot_log, "wb") if self._boot_log is not None else subprocess.DEVNULL
        )
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
        self._drop_monitor()
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

    def is_alive(self) -> bool:
        """True if we own a still-running x64sc process (or don't own one)."""
        if self.proc is None:
            # We attached to an externally launched emulator; trust the port.
            return self._port_open()
        return self.proc.poll() is None

    @staticmethod
    def _port_open(timeout: float = 2.0) -> bool:
        try:
            with socket.create_connection((HOST, PORT), timeout=timeout):
                return True
        except OSError:
            return False

    def ping(self) -> bool:
        """Side-effect-free round trip on the persistent monitor. Never raises.

        Returns True on success. Optional liveness probe; with the persistent
        connection the monitor no longer drifts dead on its own, so a heartbeat
        is not required, but ping() remains useful for explicit health checks.
        """
        try:
            self._with_monitor(lambda monitor: monitor.cmd("r"))
            return True
        except Exception:
            return False

    def heartbeat(self, interval_seconds: float = 20.0) -> "_Heartbeat":
        """Context manager that pings the persistent monitor periodically.

        With the persistent connection this is optional (the wedge it used to
        guard against no longer happens), but it provides early detection of a
        genuinely dead emulator during a long engine think; if a recovery
        callback is set, the dead monitor is repaired before the next op.
        """
        return _Heartbeat(self, interval_seconds)

    # -- monitor primitives ------------------------------------------------

    def _get_monitor(self) -> _Monitor:
        """Return the held monitor, opening one if needed. Caller holds lock."""
        if self._monitor is None:
            self._monitor = _Monitor(
                connect_timeout=self.connect_timeout, io_timeout=self.io_timeout
            )
        return self._monitor

    def _drop_monitor(self) -> None:
        """Discard the held monitor connection (it errored or x64sc died)."""
        monitor, self._monitor = self._monitor, None
        if monitor is not None:
            try:
                monitor.sock.close()
            except OSError:
                pass

    def _with_monitor(self, fn: Any) -> Any:
        """Run fn against the persistent monitor; resume the CPU afterward.

        Holds ONE connection for the whole game. On a socket error the dead
        connection is dropped and a single reconnect is attempted; if that also
        fails and a recovery callback is configured, x64sc is relaunched and the
        game replayed, then the op is retried once.
        """
        with self._monitor_lock:
            # First try on the held (or freshly opened) connection.
            try:
                return self._run_on_monitor(fn)
            except (ViceColossusError, OSError):
                self._drop_monitor()

            # Reconnect once: a fresh socket to a still-healthy listener.
            try:
                return self._run_on_monitor(fn)
            except (ViceColossusError, OSError):
                self._drop_monitor()
                if self.recovery_callback is None or self._recovering:
                    raise

            # Listener is wedged/dead: relaunch + replay, then retry once.
            self._recover()
            return self._run_on_monitor(fn)

    def _run_on_monitor(self, fn: Any) -> Any:
        monitor = self._get_monitor()
        try:
            # Re-enter the monitor cleanly on the held socket before the burst.
            monitor.sync_prompt()
            result = fn(monitor)
        except Exception:
            # Leave the connection in a known state for the retry path.
            self._drop_monitor()
            raise
        # Resume the CPU but KEEP the socket open for the next operation.
        monitor.resume()
        return result

    def _recover(self) -> None:
        """Relaunch x64sc and let the callback restore identical board state."""
        if self.recovery_callback is None:
            raise ViceColossusError("monitor unreachable and no recovery callback configured")
        self._recovering = True
        try:
            # Drop the dead socket and tear down the wedged emulator so the
            # relaunch owns the port.
            self._drop_monitor()
            self.kill()
            try:
                subprocess.run(["pkill", "-f", "x64sc"], check=False)
            except Exception:
                pass
            time.sleep(2.0)
            # launch() blocks until the monitor port is reachable again. The
            # recovery callback owns "board ready" semantics (it waits for the
            # restored move list), so we do not assume a Colossus-specific
            # boot screen here.
            self.launch(boot_log=self._boot_log)
            # Callback re-disables prediction and replays the engine's moves so
            # far; replay is deterministic from the known move list.
            self.recovery_callback(self)
        finally:
            self._recovering = False

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
