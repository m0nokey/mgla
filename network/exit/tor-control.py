#!/usr/bin/env python3
import socket
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: tor-control SOCKET COMMAND [COMMAND...]", file=sys.stderr)
        return 2

    sock_path = sys.argv[1]
    commands = sys.argv[2:]
    payload = "".join(
        command.rstrip("\r\n") + "\r\n" for command in commands
    )
    payload += "quit\r\n"

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5)
        sock.connect(sock_path)
        sock.sendall(payload.encode("utf-8"))

        chunks = []
        while True:
            try:
                data = sock.recv(4096)
            except socket.timeout:
                break
            if not data:
                break
            chunks.append(data)

    sys.stdout.buffer.write(b"".join(chunks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
