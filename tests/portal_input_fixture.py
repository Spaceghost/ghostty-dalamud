import argparse
import socket
import struct
import time
import os
import signal

def terminate(_signum, _frame):
    raise SystemExit(0)

signal.signal(signal.SIGTERM, terminate)
parser = argparse.ArgumentParser()
parser.add_argument('--socket-fd', type=int, required=True)
parser.add_argument('--input', action='store_true')
args = parser.parse_args()
assert args.input
try:
    with socket.socket(fileno=args.socket_fd) as connection:
        connection.settimeout(3)
        data = bytearray()
        while len(data) < 32:
            chunk = connection.recv(32 - len(data))
            assert chunk
            data.extend(chunk)
        assert struct.unpack('<4sBBHiiiiiHH', data) == (b'PGI1', 2, 1, 0, 10, 20, 1, 0, 0, 0, 0)
        connection.sendall(struct.pack('<4sIIQI', b'PGF1', 1, 1, 1, 4) + b'PASS')
        time.sleep(1)
finally:
    marker = os.environ.get('GHOSTTY_PORTAL_CLOSE_MARKER')
    if marker:
        with open(marker, 'w') as output:
            output.write('closed')
