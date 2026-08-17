#!/usr/bin/env python3
"""Raw independent HTTP/1.1 server for zig-http response-decoder interop."""
from __future__ import annotations

import argparse
import socket


def fragmented_send(sock: socket.socket, data: bytes) -> None:
    pattern = (1, 2, 5, 3, 8, 13)
    pos = 0
    i = 0
    while pos < len(data):
        n = min(pattern[i % len(pattern)], len(data) - pos)
        sock.sendall(data[pos : pos + n])
        pos += n
        i += 1


def read_head(sock: socket.socket, buffered: bytes) -> tuple[bytes, bytes]:
    data = bytearray(buffered)
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError("client closed while server awaited request")
        data.extend(chunk)
    head, rest = bytes(data).split(b"\r\n\r\n", 1)
    return head, rest


def serve(host: str, port: int) -> None:
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((host, port))
    listener.listen(1)
    print(f"LISTEN {listener.getsockname()[1]}", flush=True)
    sock, _ = listener.accept()
    listener.close()
    sock.settimeout(5)
    buffered = b""

    cases = [
        (b"GET", b"/early", b"HTTP/1.1 103 Early Hints\r\nLink: </a>; rel=preload\r\n\r\n"
         b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\nX-Server: python\r\n\r\nzig-http1"),
        (b"HEAD", b"/head", b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n"),
        (b"GET", b"/chunked", b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
         b"3 ; sig = \"a,b\"\r\nzig\r\n6;part=two\r\n-http1\r\n0 ; end\r\nX-Trailer: done\r\n\r\n"),
        (b"GET", b"/close", b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nclose-body"),
    ]

    try:
        for method, path, response in cases:
            request, buffered = read_head(sock, buffered)
            first = request.split(b"\r\n", 1)[0].split(b" ")
            if first[:2] != [method, path]:
                raise AssertionError((first, method, path))
            fragmented_send(sock, response)
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        sock.settimeout(1)
        try:
            while sock.recv(4096):
                pass
        except (OSError, socket.timeout):
            pass
    finally:
        sock.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    serve(args.host, args.port)
