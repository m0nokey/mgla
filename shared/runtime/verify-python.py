from http.client import HTTPResponse
from io import BytesIO
from poplib import POP3
from types import SimpleNamespace

client = POP3.__new__(POP3)
client._debugging = 0
client._putline = lambda value: None
try:
    client._putcmd("NOOP\r\nQUIT")
except ValueError:
    pass
else:
    raise SystemExit("POP3 accepted a control character")

response = HTTPResponse(SimpleNamespace(makefile=lambda *args: BytesIO(
    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n+1\r\nx\r\n0\r\n\r\n"
)))
response.begin()
try:
    response._read_next_chunk_size()
except ValueError:
    pass
else:
    raise SystemExit("HTTP accepted a non-hex chunk length")

response = HTTPResponse(SimpleNamespace(makefile=lambda *args: BytesIO(
    b"HTTP/1.1 200 OK\r\nContent-Length: +1\r\n\r\nx"
)))
response.begin()
if response.length is not None:
    raise SystemExit("HTTP accepted an invalid Content-Length")
