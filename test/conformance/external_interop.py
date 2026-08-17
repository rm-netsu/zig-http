#!/usr/bin/env python3
"""External HTTP/2 interoperability checks against independent client stacks."""

from __future__ import annotations

import argparse
import socket
from dataclasses import dataclass, field

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, PingAckReceived, ResponseReceived, StreamEnded


@dataclass
class Result:
    status: str | None = None
    body: bytearray = field(default_factory=bytearray)
    ended: bool = False


def request_headers(authority: str, method: str = "GET", path: str = "/") -> list[tuple[str, str]]:
    return [
        (":method", method),
        (":scheme", "http"),
        (":authority", authority),
        (":path", path),
    ]


def send_fragmented(sock: socket.socket, wire: bytes) -> None:
    """Deliberately avoid preserving HTTP/2 frame boundaries on the socket."""
    pattern = (1, 2, 3, 5, 8, 13, 21)
    offset = 0
    index = 0
    while offset < len(wire):
        size = pattern[index % len(pattern)]
        sock.sendall(wire[offset : offset + size])
        offset += size
        index += 1


def run(host: str, port: int) -> None:
    authority = f"{host}:{port}"
    conn = H2Connection(config=H2Configuration(client_side=True, header_encoding="utf-8"))
    sock = socket.create_connection((host, port), timeout=3)
    sock.settimeout(3)
    try:
        conn.initiate_connection()
        send_fragmented(sock, conn.data_to_send())

        # Exercise a dense batch of multiplexed requests on one connection.
        # Fragmenting the generated wire bytes independently of frame boundaries
        # also checks transport streaming behavior instead of only codec logic.
        stream_ids = tuple(range(1, 32, 2))
        conn.send_headers(1, request_headers(authority, "GET", "/first"), end_stream=True)
        post_headers = request_headers(authority, "POST", "/post")
        post_headers.append(("content-length", "7"))
        conn.send_headers(3, post_headers, end_stream=False)
        conn.send_data(3, b"payload", end_stream=True)
        for stream_id in stream_ids[2:]:
            conn.send_headers(
                stream_id,
                request_headers(authority, "GET", f"/multiplex/{stream_id}"),
                end_stream=True,
            )
        ping_data = b"zig-http"
        conn.ping(ping_data)
        send_fragmented(sock, conn.data_to_send())

        results = {stream_id: Result() for stream_id in stream_ids}
        ping_acked = False
        while not (all(result.ended for result in results.values()) and ping_acked):
            wire = sock.recv(65535)
            if not wire:
                raise RuntimeError("server closed the connection before all responses completed")
            for event in conn.receive_data(wire):
                if isinstance(event, ResponseReceived):
                    result = results[event.stream_id]
                    result.status = dict(event.headers).get(":status")
                elif isinstance(event, DataReceived):
                    result = results[event.stream_id]
                    result.body.extend(event.data)
                    conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                elif isinstance(event, StreamEnded):
                    results[event.stream_id].ended = True
                elif isinstance(event, PingAckReceived):
                    if event.ping_data == ping_data:
                        ping_acked = True
            pending = conn.data_to_send()
            if pending:
                send_fragmented(sock, pending)

        for stream_id, result in results.items():
            if result.status != "200" or bytes(result.body) != b"zig-http":
                raise AssertionError(
                    f"stream {stream_id}: expected status=200 body=b'zig-http', "
                    f"got status={result.status!r} body={bytes(result.body)!r}"
                )
        if not ping_acked:
            raise AssertionError("PING acknowledgement was not received")
    finally:
        sock.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    run(args.host, args.port)
    print("hyper-h2 interoperability: PASS")
