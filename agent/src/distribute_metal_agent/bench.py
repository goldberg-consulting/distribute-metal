"""Bounded in-process TCP benchmarking for peer link tests."""

from __future__ import annotations

import socket
import threading
import time
from dataclasses import dataclass

from .models import BenchResultResponse, BenchResultState, BenchSenderResponse

MAX_CONCURRENT_RECEIVERS = 4
RECEIVER_TIMEOUT_SECONDS = 30
RESULT_TTL_SECONDS = 300
DEFAULT_BUFFER_SIZE = 1024 * 1024


@dataclass
class BenchSession:
    session_id: str
    server: socket.socket
    port: int
    max_bytes: int
    created_at: float
    state: BenchResultState = BenchResultState.pending
    bytes_received: int = 0
    duration_seconds: float | None = None
    error: str | None = None


_sessions: dict[str, BenchSession] = {}
_lock = threading.Lock()


def start_receiver(session_id: str, max_bytes: int) -> int:
    with _lock:
        _cleanup_expired_locked()
        if session_id in _sessions:
            raise ValueError(f"Benchmark session already exists: {session_id}")

        pending_receivers = sum(1 for session in _sessions.values() if session.state == BenchResultState.pending)
        if pending_receivers >= MAX_CONCURRENT_RECEIVERS:
            raise RuntimeError("Too many active benchmark receivers")

        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("0.0.0.0", 0))
        server.listen(1)
        server.settimeout(RECEIVER_TIMEOUT_SECONDS)

        session = BenchSession(
            session_id=session_id,
            server=server,
            port=server.getsockname()[1],
            max_bytes=max_bytes,
            created_at=time.time(),
        )
        _sessions[session_id] = session

    thread = threading.Thread(target=_run_receiver, args=(session_id,), daemon=True)
    thread.start()
    return session.port


def run_sender(
    session_id: str,
    host: str,
    port: int,
    bytes_to_send: int,
    chunk_size: int,
) -> BenchSenderResponse:
    payload = b"\0" * min(chunk_size, DEFAULT_BUFFER_SIZE)

    connect_started = time.monotonic()
    with socket.create_connection((host, port), timeout=RECEIVER_TIMEOUT_SECONDS) as client:
        connect_latency_ms = (time.monotonic() - connect_started) * 1000
        started = time.monotonic()
        remaining = bytes_to_send
        while remaining > 0:
            piece = payload[: min(len(payload), remaining)]
            client.sendall(piece)
            remaining -= len(piece)
        duration_seconds = max(time.monotonic() - started, 1e-6)

    throughput_mbps = (bytes_to_send * 8) / duration_seconds / 1_000_000
    return BenchSenderResponse(
        session_id=session_id,
        bytes_sent=bytes_to_send,
        duration_seconds=duration_seconds,
        throughput_mbps=throughput_mbps,
        connect_latency_ms=connect_latency_ms,
    )


def get_result(session_id: str) -> BenchResultResponse:
    with _lock:
        _cleanup_expired_locked()
        session = _sessions.get(session_id)
        if session is None:
            raise KeyError(session_id)
        return BenchResultResponse(
            session_id=session.session_id,
            state=session.state,
            bytes_received=session.bytes_received,
            duration_seconds=session.duration_seconds,
            throughput_mbps=_throughput(session.bytes_received, session.duration_seconds),
            error=session.error,
        )


def _run_receiver(session_id: str) -> None:
    with _lock:
        session = _sessions.get(session_id)
    if session is None:
        return

    connection: socket.socket | None = None
    try:
        connection, _ = session.server.accept()
        connection.settimeout(RECEIVER_TIMEOUT_SECONDS)

        total = 0
        started = time.monotonic()
        while total < session.max_bytes:
            chunk = connection.recv(min(DEFAULT_BUFFER_SIZE, session.max_bytes - total))
            if not chunk:
                break
            total += len(chunk)

        duration_seconds = max(time.monotonic() - started, 1e-6)
        with _lock:
            current = _sessions.get(session_id)
            if current is not None:
                current.bytes_received = total
                current.duration_seconds = duration_seconds
                current.state = BenchResultState.completed
    except Exception as exc:
        with _lock:
            current = _sessions.get(session_id)
            if current is not None:
                current.state = BenchResultState.failed
                current.error = str(exc)
    finally:
        if connection is not None:
            connection.close()
        session.server.close()


def _cleanup_expired_locked() -> None:
    cutoff = time.time() - RESULT_TTL_SECONDS
    expired = [session_id for session_id, session in _sessions.items() if session.created_at < cutoff]
    for session_id in expired:
        session = _sessions.pop(session_id)
        try:
            session.server.close()
        except OSError:
            pass


def _throughput(bytes_received: int, duration_seconds: float | None) -> float | None:
    if duration_seconds is None or duration_seconds <= 0:
        return None
    return (bytes_received * 8) / duration_seconds / 1_000_000
