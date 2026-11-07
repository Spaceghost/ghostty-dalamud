import argparse
import socket
import struct
import os
parser = argparse.ArgumentParser()
parser.add_argument('--socket-fd', type=int, required=True)
args = parser.parse_args()
if os.environ.get('GHOSTTY_PORTAL_FIXTURE_STARTS'):
    with open(os.environ['GHOSTTY_PORTAL_FIXTURE_STARTS'], 'a') as starts:
        starts.write('started\n')
with socket.socket(fileno=args.socket_fd) as connection:
    for serial in (1, 2):
        connection.sendall(struct.pack('<4sIIQI', b'PGF1', 1, 1, serial, 4) + b'BGRA')

    import os, time
    time.sleep(float(os.environ.get("GHOSTTY_PORTAL_FIXTURE_HOLD", "0")))
