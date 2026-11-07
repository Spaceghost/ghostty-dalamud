#!/usr/bin/env python3
"""Run compiled portal-agent fixture test; never opens a desktop chooser."""
import os
from pathlib import Path
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


def receive(connection, wanted):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        kind, size = struct.unpack('<BI', exact(connection, 5))
        assert size <= 16 * 1024 * 1024
        body = exact(connection, size)
        if kind == wanted:
            return body
    raise TimeoutError(f'no protocol message {wanted}')


def verify_handoff(port, binary, token_file, marker):
    with socket.create_connection(('127.0.0.1', port), timeout=5) as watcher:
        send(watcher, 1, b'portal-fixture-token')
        receive(watcher, 16)
        send(watcher, 11, b'watch')
        receive(watcher, 24)
        before = len(marker.read_text().splitlines())
        subprocess.run([binary, '--listen', f'127.0.0.1:{port}', '--token-file', str(token_file),
                        '--send-to-game'], check=True, timeout=15)
        # The CLI has disconnected before the game client attaches.
        while True:
            rows = receive(watcher, 24).decode().splitlines()
            raised = [row.split('\t') for row in rows if '\traise:' in row]
            if raised:
                break
        assert len(raised) == 1
        wid = int(raised[0][0])
        assert wid > 0
        send(watcher, 12, struct.pack('<IIHHB', 900, wid, 1024, 768, 30))
        opened = receive(watcher, 25)
        request, sid, width, height = struct.unpack_from('<IIHH', opened)
        assert request == 900 and sid > 0 and (width, height) == (1, 1)
        frame = receive(watcher, 26)
        assert struct.unpack_from('<I', frame)[0] == sid
        assert len(marker.read_text().splitlines()) == before + 1, 'attachment started a second helper'
        send(watcher, 15, struct.pack('<I', sid))
        print('portal watcher handoff OK')

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ghostty-portal-test-') as scratch:
    token_file = Path(scratch) / 'token'
    token_file.write_text('portal-fixture-token\n')
    token_file.chmod(0o600)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    env = dict(os.environ, GHOSTTY_PORTAL_HELPER=str(root / 'tests/portal_process_fixture.py'),
               GHOSTTY_PORTAL_FIXTURE_HOLD='1')
    marker = Path(scratch) / 'helper-starts'
    marker.write_text('')
    env['GHOSTTY_PORTAL_FIXTURE_STARTS'] = str(marker)
    with open(root / 'build/portal-agent-test.log', 'w') as log:
        agent = subprocess.Popen([os.environ.get('GHOSTTY_PORTAL_TEST_AGENT', str(root / 'build/ghostty-agent-votes')), '--listen', f'127.0.0.1:{port}',
            '--token-file', str(token_file), '--windows', 'portal'], env=env, stdout=log, stderr=log, cwd=root)
        try:
            deadline = time.monotonic() + 5
            while True:
                if agent.poll() is not None:
                    raise RuntimeError('fixture agent exited; see build/portal-agent-test.log')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('fixture agent did not listen')
                    time.sleep(0.02)
            subprocess.run([str(root / 'build/nelua-cache/test_agent_portal'), str(port), 'portal-fixture-token'],
                           check=True, cwd=root, timeout=15)
            verify_handoff(port, os.environ.get('GHOSTTY_PORTAL_TEST_AGENT', str(root / 'build/ghostty-agent-votes')),
                           token_file, marker)
        finally:
            agent.terminate()
            try:
                agent.wait(timeout=3)
            except subprocess.TimeoutExpired:
                agent.kill()
                agent.wait()
