"""Exercise the modules and control connection used by Nyx."""

import curses
import nyx
import os
import pty
from stem.control import Controller

master, terminal = pty.openpty()
try:
    curses.setupterm(term="xterm", fd=terminal)
    if curses.tigetnum("colors") < 8:
        raise SystemExit("Nyx terminal data is missing")
finally:
    os.close(master)
    os.close(terminal)
with Controller.from_socket_file(path="/run/tor/control.sock") as controller:
    controller.authenticate()
    if "PROGRESS=100" not in controller.get_info("status/bootstrap-phase"):
        raise SystemExit("Nyx controller reached an unready Tor process")
    if "BUILT" not in controller.get_info("circuit-status"):
        raise SystemExit("Nyx controller cannot read a built Tor circuit")
    if not controller.get_version():
        raise SystemExit("Nyx controller cannot read the Tor version")
print("Nyx imports, terminal data, authentication, and Tor status queries passed")
