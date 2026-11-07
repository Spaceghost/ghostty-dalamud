#!/usr/bin/env python3
"""Private compositor -> authenticated watcher, synthetic notification only."""
import json
import argparse
import os
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import tempfile
import time


def send(connection, kind, body=b''):
    connection.sendall(struct.pack('<BI', kind, len(body)) + body)


def exact(connection, size):
    result = bytearray()
    while len(result) < size:
        chunk = connection.recv(size - len(result))
        if not chunk:
            raise EOFError('agent disconnected')
        result.extend(chunk)
    return bytes(result)


def receive(connection):
    kind, size = struct.unpack('<BI', exact(connection, 5))
    assert size <= 16 * 1024 * 1024
    return kind, exact(connection, size)


root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--agent', type=Path, default=root / 'build/ghostty-agent-notifications')
parser.add_argument('--installed-helpers', action='store_true', help='Use the packaged helper path without an override')
options = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='ghostty-notification-agent-') as scratch:
    token = Path(scratch) / 'token'
    token.write_text('private-notification-fixture-token\n')
    token.chmod(0o600)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    env = dict(os.environ, XDG_RUNTIME_DIR=scratch,
               DBUS_SESSION_BUS_ADDRESS='unix:path=' + scratch + '/parent-bus-must-not-be-used')
    if options.installed_helpers:
        env.pop('GHOSTTY_NOTIFICATION_HELPER', None)
    else:
        env['GHOSTTY_NOTIFICATION_HELPER'] = str(root / 'tools/app_notifications.py')
    env.pop('DISPLAY', None)
    env.pop('WAYLAND_DISPLAY', None)
    with (Path(scratch) / 'agent.log').open('w') as log:
        agent = subprocess.Popen([str(options.agent.resolve()), '--listen', f'127.0.0.1:{port}',
                                  '--token-file', str(token), '--windows', 'wayland', '--wayland-render-node', 'none',
                                  '--wayland-socket', f'notification-agent-{os.getpid()}', '--wireguard', 'off'],
                                 env=env, stdout=log, stderr=log)
        connections = []
        try:
            deadline = time.monotonic() + 5
            while True:
                if agent.poll() is not None:
                    raise RuntimeError('agent exited')
                try:
                    watcher = socket.create_connection(('127.0.0.1', port), timeout=3)
                    connections.append(watcher)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('agent did not listen')
                    time.sleep(0.02)
            idle = socket.create_connection(('127.0.0.1', port), timeout=3)
            connections.append(idle)
            for connection in connections:
                send(connection, 1, b'private-notification-fixture-token')
                assert receive(connection)[0] == 16
            send(watcher, 11, b'watch')
            assert receive(watcher)[0] == 24
            marker = Path(scratch) / 'client.txt'
            command = 'run:python3 ' + shlex.quote(str(root / 'tests/fixtures/notify_client.py'))
            command += ' ' + shlex.quote(str(marker)) + ' 20'
            send(watcher, 12, struct.pack('<IIHHB', 900, 0, 400, 200, 1) + command.encode())
            deadline = time.monotonic() + 5
            events = []
            while time.monotonic() < deadline:
                kind, body = receive(watcher)
                if kind == 53:
                    events.append(json.loads(body))
                    if len(events) == 20:
                        break
            assert len(events) == 20, len(events)
            for index, event in enumerate(events):
                assert event['summary'] == f'Synthetic compositor message #{index}'
                assert event['body'] == 'Synthetic notification body'
                assert event['desktop_entry'] == 'fixture.desktop'
            assert len({event['id'] for event in events}) == 20
            deadline = time.monotonic() + 3
            while not marker.exists() or not marker.read_text():
                if time.monotonic() >= deadline:
                    raise TimeoutError('notification client did not complete')
                time.sleep(0.01)
            assert marker.read_text().splitlines()[0].startswith('unix:')
            assert marker.read_text().splitlines()[0] != env['DBUS_SESSION_BUS_ADDRESS']
            idle.settimeout(0.2)
            try:
                kind, _ = receive(idle)
            except socket.timeout:
                pass
            else:
                raise AssertionError(f'non-watcher received unsolicited frame {kind}')
            print('notification app -> private bus -> authenticated watcher OK')
        except Exception:
            log.flush()
            print((Path(scratch) / 'agent.log').read_text())
            raise
        finally:
            for connection in connections:
                connection.close()
            agent.terminate()
            try:
                agent.wait(timeout=3)
            except subprocess.TimeoutExpired:
                agent.kill()
                agent.wait()
