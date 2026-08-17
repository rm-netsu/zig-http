#!/usr/bin/env python3
"""Independent hyper-h2 server for exercising zig-http's HTTP/2 client role."""
from __future__ import annotations

import argparse
import socket

import h2.config
import h2.connection
import h2.events
import h2.settings


def send_fragmented(sock: socket.socket, data: bytes) -> None:
    pattern = (1, 2, 3, 5, 8, 13)
    pos = 0
    index = 0
    while pos < len(data):
        n = min(pattern[index % len(pattern)], len(data) - pos)
        sock.sendall(data[pos : pos + n])
        pos += n
        index += 1


def serve(host: str, port: int) -> None:
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((host, port))
    listener.listen(1)
    print(f"LISTEN {listener.getsockname()[1]}", flush=True)
    conn_sock, _ = listener.accept()
    listener.close()
    conn_sock.settimeout(5)

    config = h2.config.H2Configuration(client_side=False, header_encoding="utf-8")
    h2c = h2.connection.H2Connection(config=config)
    h2c.initiate_connection()
    h2c.update_settings({h2.settings.SettingCodes.ENABLE_CONNECT_PROTOCOL: 1})
    send_fragmented(conn_sock, h2c.data_to_send())

    completed: set[int] = set()
    expected = {1, 3, 5, 7}
    try:
        while completed != expected:
            data = conn_sock.recv(65535)
            if not data:
                raise RuntimeError("zig-http client closed before all requests completed")
            events = h2c.receive_data(data)
            for event in events:
                if isinstance(event, h2.events.RequestReceived):
                    headers = dict(event.headers)
                    stream_id = event.stream_id
                    method = headers.get(":method")
                    path = headers.get(":path")
                    if stream_id == 1:
                        if method != "GET" or path != "/early":
                            raise AssertionError((stream_id, headers))
                        h2c.send_headers(stream_id, [(":status", "103"), ("link", "</style.css>; rel=preload")])
                        h2c.send_headers(stream_id, [(":status", "200"), ("content-length", "8"), ("x-server", "hyper-h2")])
                        h2c.send_data(stream_id, b"zig-http", end_stream=True)
                    elif stream_id == 3:
                        if method != "HEAD" or path != "/head":
                            raise AssertionError((stream_id, headers))
                        h2c.send_headers(stream_id, [(":status", "200"), ("content-length", "8")], end_stream=True)
                    elif stream_id == 5:
                        if method != "GET" or path != "/trailers":
                            raise AssertionError((stream_id, headers))
                        h2c.send_headers(stream_id, [(":status", "200")])
                        h2c.send_data(stream_id, b"payload", end_stream=False)
                        h2c.send_headers(stream_id, [("x-trailer", "done")], end_stream=True)
                    elif stream_id == 7:
                        if method != "CONNECT" or path != "/extended" or headers.get(":protocol") != "websocket":
                            raise AssertionError((stream_id, headers))
                        h2c.send_headers(stream_id, [(":status", "200")], end_stream=True)
                    else:
                        raise AssertionError(f"unexpected stream {stream_id}")
                elif isinstance(event, h2.events.StreamEnded):
                    # Request streams are header-only. Mark completion only after
                    # the response has been queued for that stream.
                    completed.add(event.stream_id)
                elif isinstance(event, h2.events.PingReceived):
                    # hyper-h2 automatically queues the ACK.
                    pass
            pending = h2c.data_to_send()
            if pending:
                send_fragmented(conn_sock, pending)
    finally:
        try:
            conn_sock.shutdown(socket.SHUT_WR)
            conn_sock.settimeout(1)
            while conn_sock.recv(4096):
                pass
        except (OSError, socket.timeout):
            pass
        conn_sock.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    serve(args.host, args.port)
