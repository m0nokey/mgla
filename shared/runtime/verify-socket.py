"""Exercise the native resolver without DNS or external network access."""

import _socket
import inspect
import socket

if not inspect.isbuiltin(_socket.getaddrinfo):
    raise SystemExit("Expected the native _socket.getaddrinfo implementation")

hosts = (
    "127.0.0.1\0.invalid", b"127.0.0.1\0.invalid",
    "localhost\0", b"localhost\0", "\0localhost", b"\0localhost",
    "\0", b"\0", "b\u00fccher\0.example",
)
ports = ("8\x000", b"8\x000", "http\0", b"http\0", "\0", b"\0")
for function in (_socket.getaddrinfo, socket.getaddrinfo):
    for label, values in (("host", hosts), ("port", ports)):
        for value in values:
            arguments = (value, 80) if label == "host" else ("127.0.0.1", value)
            try:
                function(*arguments)
            except ValueError as error:
                if label not in str(error):
                    raise SystemExit(f"Unexpected rejection for {label}: {error}") from error
            else:
                raise SystemExit(f"Native resolver accepted NUL in {label}: {value!r}")

    for port in (0, 80, "80", b"80"):
        results = function(
            "127.0.0.1", port, socket.AF_INET, socket.SOCK_STREAM, 0,
            socket.AI_NUMERICHOST | socket.AI_NUMERICSERV,
        )
        if not results or any(result[4] != ("127.0.0.1", int(port)) for result in results):
            raise SystemExit("Numeric address resolution failed")

left, right = socket.socketpair()
with left, right:
    left.settimeout(2)
    right.settimeout(2)
    left.sendall(b"native-socket-check")
    if right.recv(64) != b"native-socket-check":
        raise SystemExit("Native socket I/O failed")
print("Native resolver rejects NUL bytes; numeric resolution and socket I/O passed")
