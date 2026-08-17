#!/usr/bin/env python3
"""Small raw-wire RFC/h2spec regression set runnable without the h2spec binary."""

from __future__ import annotations

import argparse
import socket
import struct
from dataclasses import dataclass

from hpack import Encoder

PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
DATA = 0x0
HEADERS = 0x1
PRIORITY = 0x2
RST_STREAM = 0x3
SETTINGS = 0x4
PING = 0x6
GOAWAY = 0x7
WINDOW_UPDATE = 0x8
CONTINUATION = 0x9

END_STREAM = 0x1
ACK = 0x1
END_HEADERS = 0x4
PADDED = 0x8

PROTOCOL_ERROR = 0x1
FLOW_CONTROL_ERROR = 0x3
STREAM_CLOSED = 0x5
FRAME_SIZE_ERROR = 0x6
COMPRESSION_ERROR = 0x9


@dataclass(frozen=True)
class Frame:
    type: int
    flags: int
    stream_id: int
    payload: bytes


def frame(frame_type: int, flags: int, stream_id: int, payload: bytes = b"") -> bytes:
    length = len(payload)
    if length > 0xFFFFFF:
        raise ValueError("frame payload is too large")
    return length.to_bytes(3, "big") + bytes((frame_type, flags)) + (stream_id & 0x7FFFFFFF).to_bytes(4, "big") + payload


def recv_exact(sock: socket.socket, n: int) -> bytes:
    out = bytearray()
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise EOFError(f"EOF while waiting for {n} bytes")
        out.extend(chunk)
    return bytes(out)


def recv_frame(sock: socket.socket) -> Frame:
    head = recv_exact(sock, 9)
    length = int.from_bytes(head[:3], "big")
    return Frame(head[3], head[4], int.from_bytes(head[5:9], "big") & 0x7FFFFFFF, recv_exact(sock, length))


def connect(host: str, port: int) -> socket.socket:
    sock = socket.create_connection((host, port), timeout=3)
    sock.settimeout(3)
    sock.sendall(PREFACE + frame(SETTINGS, 0, 0))
    first = recv_frame(sock)
    if first.type != SETTINGS or first.flags & ACK:
        raise AssertionError(f"server preface must start with non-ACK SETTINGS, got {first}")
    sock.sendall(frame(SETTINGS, ACK, 0))
    # The server acknowledgement for our initial SETTINGS can race with test
    # traffic. Leave it queued and make expectation helpers ignore it.
    return sock


def next_error(sock: socket.socket, expected_type: int, expected_stream: int, expected_code: int) -> None:
    for _ in range(128):
        current = recv_frame(sock)
        if current.type == SETTINGS:
            continue
        if current.type not in (RST_STREAM, GOAWAY):
            # Successful response frames from an earlier request can precede the
            # deliberately triggered protocol error.
            continue
        if current.type != expected_type:
            raise AssertionError(f"expected error frame type {expected_type}, got {current}")
        if expected_type == RST_STREAM:
            code = struct.unpack("!I", current.payload)[0]
            stream_id = current.stream_id
        else:
            stream_id, code = struct.unpack("!II", current.payload[:8])
            stream_id &= 0x7FFFFFFF
        if stream_id != expected_stream or code != expected_code:
            raise AssertionError(
                f"expected stream={expected_stream} code={expected_code}, got stream={stream_id} code={code}"
            )
        return
    raise AssertionError("expected protocol error frame was not received")


def next_ping_ack(sock: socket.socket, payload: bytes) -> None:
    for _ in range(64):
        current = recv_frame(sock)
        if current.type == SETTINGS:
            continue
        if current.type == PING:
            if not current.flags & ACK or current.stream_id != 0 or current.payload != payload:
                raise AssertionError(f"invalid PING acknowledgement: {current}")
            return
    raise AssertionError("expected PING acknowledgement was not received")


def next_settings_ack(sock: socket.socket) -> None:
    for _ in range(64):
        current = recv_frame(sock)
        if current.type == SETTINGS and current.flags & ACK:
            return
    raise AssertionError("expected SETTINGS acknowledgement was not received")


def request_block(encoder: Encoder, path: str = "/") -> bytes:
    return encoder.encode([
        (b":method", b"GET"),
        (b":scheme", b"http"),
        (b":path", path.encode()),
        (b":authority", b"localhost"),
    ])


def probe_invalid_preface(host: str, port: int) -> None:
    sock = socket.create_connection((host, port), timeout=3)
    sock.settimeout(3)
    try:
        bad_preface = PREFACE[:-1] + b"X"
        sock.sendall(bad_preface)
        next_error(sock, GOAWAY, 0, PROTOCOL_ERROR)
    finally:
        sock.close()


def probe_regressed_stream_id(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        encoder = Encoder()
        sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 5, request_block(encoder, "/five")))
        sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 3, request_block(encoder, "/three")))
        next_error(sock, GOAWAY, 0, PROTOCOL_ERROR)
    finally:
        sock.close()


def probe_priority_self_dependency(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        sock.sendall(frame(PRIORITY, 0, 1, struct.pack("!IB", 1, 255)))
        next_error(sock, RST_STREAM, 1, PROTOCOL_ERROR)
    finally:
        sock.close()


def probe_priority_size_scope(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        sock.sendall(frame(PRIORITY, 0, 1, b"\x00" * 4))
        next_error(sock, RST_STREAM, 1, FRAME_SIZE_ERROR)
    finally:
        sock.close()


def probe_oversized_data_scope(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        encoder = Encoder()
        sock.sendall(frame(HEADERS, END_HEADERS, 1, request_block(encoder)))
        sock.sendall(frame(DATA, END_STREAM, 1, b"x" * 16385))
        next_error(sock, RST_STREAM, 1, FRAME_SIZE_ERROR)
    finally:
        sock.close()


def probe_oversized_headers_scope(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 1, b"x" * 16385))
        next_error(sock, GOAWAY, 0, FRAME_SIZE_ERROR)
    finally:
        sock.close()


def probe_rst_size_scope(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        encoder = Encoder()
        sock.sendall(frame(HEADERS, END_HEADERS, 1, request_block(encoder)))
        sock.sendall(frame(RST_STREAM, 0, 1, b"\x00" * 3))
        next_error(sock, GOAWAY, 0, FRAME_SIZE_ERROR)
    finally:
        sock.close()


def probe_invalid_setting(host: str, port: int) -> None:
    cases = [
        # SETTINGS_ENABLE_PUSH is restricted to 0 or 1.
        (2, 2, PROTOCOL_ERROR),
        # SETTINGS_INITIAL_WINDOW_SIZE cannot exceed 2^31 - 1.
        (4, 0x80000000, FLOW_CONTROL_ERROR),
        # SETTINGS_MAX_FRAME_SIZE is restricted to [2^14, 2^24 - 1].
        (5, 16383, PROTOCOL_ERROR),
        (5, 16777216, PROTOCOL_ERROR),
    ]
    for setting_id, value, code in cases:
        sock = connect(host, port)
        try:
            sock.sendall(frame(SETTINGS, 0, 0, struct.pack("!HI", setting_id, value)))
            next_error(sock, GOAWAY, 0, code)
        finally:
            sock.close()


def probe_zero_window_update_scope(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        encoder = Encoder()
        sock.sendall(frame(HEADERS, END_HEADERS, 1, request_block(encoder)))
        sock.sendall(frame(WINDOW_UPDATE, 0, 1, b"\x00" * 4))
        next_error(sock, RST_STREAM, 1, PROTOCOL_ERROR)
    finally:
        sock.close()

    sock = connect(host, port)
    try:
        sock.sendall(frame(WINDOW_UPDATE, 0, 0, b"\x00" * 4))
        next_error(sock, GOAWAY, 0, PROTOCOL_ERROR)
    finally:
        sock.close()



def probe_window_update_size_scope(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        encoder = Encoder()
        sock.sendall(frame(HEADERS, END_HEADERS, 1, request_block(encoder)))
        sock.sendall(frame(WINDOW_UPDATE, 0, 1, b"\x00" * 3))
        next_error(sock, GOAWAY, 0, FRAME_SIZE_ERROR)
    finally:
        sock.close()



def probe_padding_errors(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        encoder = Encoder()
        headers = encoder.encode([
            (b":method", b"POST"),
            (b":scheme", b"http"),
            (b":path", b"/padding"),
            (b":authority", b"localhost"),
            (b"content-length", b"4"),
        ])
        sock.sendall(frame(HEADERS, END_HEADERS, 1, headers))
        # Payload length is 5, but pad length claims 6 octets.
        sock.sendall(frame(DATA, END_STREAM | PADDED, 1, b"\x06Test"))
        next_error(sock, GOAWAY, 0, PROTOCOL_ERROR)
    finally:
        sock.close()

    sock = connect(host, port)
    try:
        block = request_block(Encoder())
        # One pad-length byte plus the HPACK block, with no actual padding.
        payload = bytes((len(block) + 1,)) + block
        sock.sendall(frame(HEADERS, END_STREAM | END_HEADERS | PADDED, 1, payload))
        next_error(sock, GOAWAY, 0, PROTOCOL_ERROR)
    finally:
        sock.close()


def probe_stream_state_errors(host: str, port: int) -> None:
    idle_cases = [
        frame(DATA, END_STREAM, 1, b"x"),
        frame(RST_STREAM, 0, 1, struct.pack("!I", 8)),
        frame(WINDOW_UPDATE, 0, 1, struct.pack("!I", 1)),
        frame(CONTINUATION, END_HEADERS, 1, request_block(Encoder())),
    ]
    for wire in idle_cases:
        sock = connect(host, port)
        try:
            sock.sendall(wire)
            next_error(sock, GOAWAY, 0, PROTOCOL_ERROR)
        finally:
            sock.close()

    # Keep the local response side open by reducing the peer-advertised send
    # window to zero. Once the remote side ended the stream, DATA and a second
    # HEADERS section must report a stream-scoped STREAM_CLOSED. The second
    # HEADERS block intentionally contains request pseudo-fields so trailer
    # validation cannot mask the state error.
    for second_frame in (DATA, HEADERS):
        sock = connect(host, port)
        try:
            encoder = Encoder()
            sock.sendall(frame(SETTINGS, 0, 0, struct.pack("!HI", 4, 0)))
            next_settings_ack(sock)
            sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 1, request_block(encoder)))
            if second_frame == DATA:
                sock.sendall(frame(DATA, END_STREAM, 1, b"x"))
            else:
                sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 1, request_block(encoder, "/again")))
            next_error(sock, RST_STREAM, 1, STREAM_CLOSED)
        finally:
            sock.close()

    # Once both sides have ended the stream, RFC 7540 requires a connection
    # STREAM_CLOSED error for a subsequent HEADERS frame. RFC 9113 permits this
    # stricter connection-level handling as well.
    sock = connect(host, port)
    try:
        encoder = Encoder()
        sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 1, request_block(encoder)))
        while True:
            current = recv_frame(sock)
            if current.type == DATA and current.stream_id == 1 and current.flags & END_STREAM:
                break
        sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 1, request_block(encoder, "/closed")))
        next_error(sock, GOAWAY, 0, STREAM_CLOSED)
    finally:
        sock.close()


def probe_frame_contracts(host: str, port: int) -> None:
    cases = [
        (frame(DATA, END_STREAM, 0, b"x"), PROTOCOL_ERROR),
        (frame(HEADERS, END_HEADERS | END_STREAM, 0), PROTOCOL_ERROR),
        (frame(SETTINGS, ACK, 0, b"x"), FRAME_SIZE_ERROR),
        (frame(SETTINGS, 0, 1, struct.pack("!HI", 3, 1)), PROTOCOL_ERROR),
        (frame(SETTINGS, 0, 0, b"\x00" * 3), FRAME_SIZE_ERROR),
        (frame(PING, 0, 1, b"12345678"), PROTOCOL_ERROR),
        (frame(PING, 0, 0, b"1234567"), FRAME_SIZE_ERROR),
        (frame(GOAWAY, 0, 1, b"\x00" * 8), PROTOCOL_ERROR),
        (frame(GOAWAY, 0, 0, b"\x00" * 7), FRAME_SIZE_ERROR),
    ]
    for wire, code in cases:
        sock = connect(host, port)
        try:
            sock.sendall(wire)
            next_error(sock, GOAWAY, 0, code)
        finally:
            sock.close()

    # Unknown frame types and unknown SETTINGS identifiers are extension
    # points and must not poison the connection.
    sock = connect(host, port)
    try:
        sock.sendall(frame(0xA, 0, 0, b"extension"))
        sock.sendall(frame(SETTINGS, 0, 0, struct.pack("!HI", 0xFF, 1)))
        ping = b"unknown!"
        sock.sendall(frame(PING, 0, 0, ping))
        next_ping_ack(sock, ping)
    finally:
        sock.close()


def probe_flow_control_overflow(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        sock.sendall(frame(WINDOW_UPDATE, 0, 0, struct.pack("!I", 0x7FFFFFFF)))
        next_error(sock, GOAWAY, 0, FLOW_CONTROL_ERROR)
    finally:
        sock.close()

    sock = connect(host, port)
    try:
        encoder = Encoder()
        sock.sendall(frame(HEADERS, END_HEADERS, 1, request_block(encoder)))
        sock.sendall(frame(WINDOW_UPDATE, 0, 1, struct.pack("!I", 0x7FFFFFFF)))
        next_error(sock, RST_STREAM, 1, FLOW_CONTROL_ERROR)
    finally:
        sock.close()


def probe_hpack_compression_error(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        # Indexed Header Field Representation with index 0 is invalid HPACK.
        sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 1, b"\x80"))
        next_error(sock, GOAWAY, 0, COMPRESSION_ERROR)
    finally:
        sock.close()


def probe_header_semantics(host: str, port: int) -> None:
    malformed = [
        [
            (b":method", b"GET"),
            (b":scheme", b"http"),
            (b":path", b"/"),
            (b"X-Test", b"upper"),
        ],
        [
            (b":method", b"GET"),
            (b":scheme", b"http"),
            (b":path", b"/"),
            (b"connection", b"close"),
        ],
        [
            (b":method", b"GET"),
            (b":scheme", b"http"),
            (b"x-regular", b"first"),
            (b":path", b"/late"),
        ],
        [
            (b":method", b"GET"),
            (b":path", b"/missing-scheme"),
        ],
        [
            (b":method", b"GET"),
            (b":scheme", b"http"),
            (b":path", b""),
        ],
        [
            (b":method", b"GET"),
            (b":scheme", b"http"),
            (b":path", b"/"),
            (b"te", b"gzip"),
        ],
        [
            (b":method", b"GET"),
            (b":scheme", b"https"),
            (b":path", b"relative"),
        ],
        [
            (b":method", b"GET"),
            (b":scheme", b"https"),
            (b":path", b"/"),
            (b":authority", b"user@example.com"),
        ],
        [
            (b":method", b"OPTIONS"),
            (b":scheme", b"https"),
            (b":path", b"*"),
            (b":authority", b"example.com"),
        ],
        [
            (b":method", b"CONNECT"),
            (b":authority", b"example.com"),
        ],
    ]
    for headers in malformed:
        sock = connect(host, port)
        try:
            block = Encoder().encode(headers)
            sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 1, block))
            next_error(sock, RST_STREAM, 1, PROTOCOL_ERROR)
        finally:
            sock.close()


def probe_malformed_stream_consumes_identifier(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        encoder = Encoder()
        malformed = encoder.encode([
            (b":method", b"GET"),
            (b":scheme", b"http"),
            (b":path", b""),
            (b":authority", b"localhost"),
        ])
        sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 5, malformed))
        next_error(sock, RST_STREAM, 5, PROTOCOL_ERROR)

        # The malformed stream still consumed identifier 5. A subsequently
        # created stream 3 therefore regresses the peer stream sequence.
        sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 3, request_block(encoder, "/three")))
        next_error(sock, GOAWAY, 0, PROTOCOL_ERROR)
    finally:
        sock.close()


def probe_content_length_mismatch(host: str, port: int) -> None:
    cases = [
        (b"1", [b"test"]),
        (b"5", [b"test"]),
    ]
    for expected, chunks in cases:
        sock = connect(host, port)
        try:
            block = Encoder().encode([
                (b":method", b"POST"),
                (b":scheme", b"http"),
                (b":path", b"/length"),
                (b":authority", b"localhost"),
                (b"content-length", expected),
            ])
            sock.sendall(frame(HEADERS, END_HEADERS, 1, block))
            for index, chunk in enumerate(chunks):
                flags = END_STREAM if index == len(chunks) - 1 else 0
                sock.sendall(frame(DATA, flags, 1, chunk))
            next_error(sock, RST_STREAM, 1, PROTOCOL_ERROR)
        finally:
            sock.close()

    # A non-zero Content-Length on a request that ends in HEADERS is also a
    # length mismatch even though no DATA frame follows.
    sock = connect(host, port)
    try:
        block = Encoder().encode([
            (b":method", b"POST"),
            (b":scheme", b"http"),
            (b":path", b"/length"),
            (b":authority", b"localhost"),
            (b"content-length", b"1"),
        ])
        sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, 1, block))
        next_error(sock, RST_STREAM, 1, PROTOCOL_ERROR)
    finally:
        sock.close()


def probe_concurrency_limit(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        # Keep server response DATA blocked so the first 32 request streams stay
        # active and the advertised concurrency limit is observable.
        sock.sendall(frame(SETTINGS, 0, 0, struct.pack("!HI", 4, 0)))
        encoder = Encoder()
        for index in range(33):
            stream_id = 1 + index * 2
            sock.sendall(frame(HEADERS, END_HEADERS | END_STREAM, stream_id, request_block(encoder, f"/{index}")))
        next_error(sock, RST_STREAM, 65, 0x7)
    finally:
        sock.close()


def probe_continuation_interleaving(host: str, port: int) -> None:
    sock = connect(host, port)
    try:
        block = request_block(Encoder())
        sock.sendall(frame(HEADERS, END_STREAM, 1, block))
        sock.sendall(frame(0x6, 0, 0, b"12345678"))
        next_error(sock, GOAWAY, 0, PROTOCOL_ERROR)
    finally:
        sock.close()


def run(host: str, port: int) -> None:
    probes = [
        probe_invalid_preface,
        probe_regressed_stream_id,
        probe_priority_self_dependency,
        probe_priority_size_scope,
        probe_oversized_data_scope,
        probe_oversized_headers_scope,
        probe_rst_size_scope,
        probe_invalid_setting,
        probe_zero_window_update_scope,
        probe_window_update_size_scope,
        probe_padding_errors,
        probe_stream_state_errors,
        probe_frame_contracts,
        probe_flow_control_overflow,
        probe_hpack_compression_error,
        probe_header_semantics,
        probe_malformed_stream_consumes_identifier,
        probe_content_length_mismatch,
        probe_concurrency_limit,
        probe_continuation_interleaving,
    ]
    for probe in probes:
        probe(host, port)
        print(f"{probe.__name__}: PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    run(args.host, args.port)
