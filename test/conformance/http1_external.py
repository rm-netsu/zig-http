#!/usr/bin/env python3
"""External HTTP/1.1 interoperability probes for the test-only Zig fixture."""
from __future__ import annotations

import argparse
import http.client
import socket

BODY = b"zig-http1"


def recv_response(sock: socket.socket, buffered: bytes = b"") -> tuple[int, dict[bytes, bytes], bytes, bytes]:
    data = bytearray(buffered)
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError("EOF before response head")
        data.extend(chunk)
    head, rest = bytes(data).split(b"\r\n\r\n", 1)
    lines = head.split(b"\r\n")
    status = int(lines[0].split(b" ", 2)[1])
    headers: dict[bytes, bytes] = {}
    for line in lines[1:]:
        name, value = line.split(b":", 1)
        headers[name.lower()] = value.strip()
    length = int(headers.get(b"content-length", b"0"))
    while len(rest) < length:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError("EOF before response body")
        rest += chunk
    return status, headers, rest[:length], rest[length:]


def probe_standard_client(host: str, port: int) -> None:
    conn = http.client.HTTPConnection(host, port, timeout=3)
    conn.request("GET", "/one")
    resp = conn.getresponse()
    assert resp.status == 200
    assert resp.read() == BODY

    # Reuse exactly the same HTTP/1.1 connection.
    conn.request("HEAD", "/head")
    resp = conn.getresponse()
    assert resp.status == 200
    assert resp.getheader("Content-Length") == str(len(BODY))
    assert resp.read() == b""

    conn.request("POST", "/upload", body=b"payload", headers={"Content-Length": "7"})
    resp = conn.getresponse()
    assert resp.status == 200
    assert resp.read() == BODY
    conn.close()


def probe_pipelining(host: str, port: int) -> None:
    sock = socket.create_connection((host, port), timeout=3)
    sock.settimeout(3)
    try:
        sock.sendall(
            b"GET /a HTTP/1.1\r\nHost: example.test\r\n\r\n"
            b"GET /b HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
        )
        status, _, body, rest = recv_response(sock)
        assert status == 200 and body == BODY
        status, headers, body, rest = recv_response(sock, rest)
        assert status == 200 and body == BODY
        assert headers[b"connection"].lower() == b"close"
        assert rest == b""
    finally:
        sock.close()


def probe_chunked_extensions(host: str, port: int) -> None:
    sock = socket.create_connection((host, port), timeout=3)
    sock.settimeout(3)
    try:
        sock.sendall(
            b"POST /chunked HTTP/1.1\r\n"
            b"Host: example.test\r\n"
            b"Transfer-Encoding: chunked\r\n"
            b"Connection: close\r\n\r\n"
            b"3 ; sig = \"a,b\"\r\nabc\r\n"
            b"4;token=value\r\ndefg\r\n"
            b"0 ; end\r\nX-Trailer: yes\r\n\r\n"
        )
        status, _, body, _ = recv_response(sock)
        assert status == 200 and body == BODY
    finally:
        sock.close()


def probe_strict_host(host: str, port: int) -> None:
    sock = socket.create_connection((host, port), timeout=3)
    sock.settimeout(3)
    try:
        sock.sendall(b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
        status, _, body, _ = recv_response(sock)
        assert status == 400 and body == b""
    finally:
        sock.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    probe_standard_client(args.host, args.port)
    probe_pipelining(args.host, args.port)
    probe_chunked_extensions(args.host, args.port)
    probe_strict_host(args.host, args.port)
    print("Python stdlib/raw HTTP/1.1 interoperability: PASS")


if __name__ == "__main__":
    main()
