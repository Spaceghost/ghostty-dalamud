#!/usr/bin/env python3
"""Authenticated agent against the runner's private external compositor."""
import os
from pathlib import Path
import socket
import shlex
import struct
import subprocess
import sys
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


def relevant(connection):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        kind, body = receive(connection)
        if kind not in (26, 28):
            return kind, body
    raise TimeoutError('only window frames received')


def internal_offers(connection, root, scratch):
    for index, offer in enumerate(('safe', 'sensitive')):
        log = Path(scratch) / f'internal-{offer}.log'
        command = 'run:python3 ' + shlex.quote(str(root / 'tests/fixtures/clipboard_offer.py'))
        command += ' ' + shlex.quote(str(log)) + ' ' + offer
        send(connection, 12, struct.pack('<IIHHB', 800 + index, 0, 400, 200, 1) + command.encode())
        kind, opened = relevant(connection)
        assert kind == 25
        request, sid = struct.unpack_from('<II', opened)
        assert request == 800 + index and sid > 0
        time.sleep(0.5)
        send(connection, 14, struct.pack('<IB', sid, 5) + b'\n')
        deadline = time.monotonic() + 5
        while not log.exists() or 'published:1' not in log.read_text():
            if time.monotonic() >= deadline:
                raise TimeoutError('internal client did not publish')
            time.sleep(0.02)
        expected = b'\x01fixture clipboard text' if offer == 'safe' else b'\x03'
        # Complete the initial app-to-host transfer before replacing the host
        # clipboard. GTK's publication log precedes its async text transfer.
        send(connection, 10, b'metadata')
        assert relevant(connection) == (52, expected)
        # External clipboard differs from the selected internal app offer.
        subprocess.run(['wl-copy', '--type', 'text/plain;charset=utf-8'], input=b'external changed',
                       check=True, timeout=3)
        send(connection, 10, b'metadata')
        assert relevant(connection) == (52, expected)
        activity = log.read_text()
        assert ('requested:' in activity) == (offer == 'safe'), activity
        send(connection, 15, struct.pack('<I', sid))
        time.sleep(0.5)
        send(connection, 10, b'metadata')
        restored = relevant(connection)
        assert restored == (52, b'\x01external changed'), restored
        print('authenticated internal clipboard routing:', offer, 'OK')


mode = sys.argv[1]
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ghostty-clipboard-agent-') as scratch:
    token = Path(scratch) / 'token'
    token.write_text('private-clipboard-fixture-token\n')
    token.chmod(0o600)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    env = dict(os.environ, GHOSTTY_CLIPBOARD_HELPER=str(root / 'build/dist/clipboard-snapshot'))
    if os.environ.get('GHOSTTY_CLIPBOARD_TEST_INSTALLED') == '1':
        env.pop('GHOSTTY_CLIPBOARD_HELPER', None)
    binary = os.environ.get('GHOSTTY_CLIPBOARD_TEST_AGENT', str(root / 'build/ghostty-agent-clipboard-helper'))
    arguments = [binary, '--listen', f'127.0.0.1:{port}', '--token-file', str(token)]
    if os.environ.get('GHOSTTY_CLIPBOARD_TEST_WAYLAND') == '1':
        arguments += ['--windows', 'wayland', '--wayland-socket', f'ghostty-clipboard-agent-{os.getpid()}',
                      '--wayland-render-node', 'none']
    with (Path(scratch) / 'agent.log').open('w') as log:
        agent = subprocess.Popen(arguments,
                                 env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while True:
                if agent.poll() is not None:
                    raise RuntimeError('fixture agent exited')
                try:
                    connection = socket.create_connection(('127.0.0.1', port), timeout=3)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('agent did not listen')
                    time.sleep(0.02)
            with connection:
                send(connection, 10, b'metadata')
                assert receive(connection) == (17, b'hello first')
            with socket.create_connection(('127.0.0.1', port), timeout=3) as connection:
                send(connection, 1, b'private-clipboard-fixture-token')
                assert receive(connection)[0] == 16
                send(connection, 10, b'metadata')
                if mode == 'oversized':
                    assert receive(connection) == (17, b'clipboard unavailable')
                else:
                    expected = (b'\x03' if mode == 'sensitive' else b'\x01' if mode == 'empty'
                                else b'\x01fixture external clipboard')
                    assert receive(connection) == (52, expected)
                if mode in ('safe', 'empty'):
                    send(connection, 9, b'from synthetic game')
                    assert receive(connection) == (16, b'clipboard set')
                    send(connection, 10, b'metadata')
                    assert receive(connection) == (52, b'\x01from synthetic game')
                if mode == 'internal':
                    assert os.environ.get('GHOSTTY_CLIPBOARD_TEST_WAYLAND') == '1'
                    internal_offers(connection, root, scratch)
            provider = 'Wayland backend' if os.environ.get('GHOSTTY_CLIPBOARD_TEST_WAYLAND') == '1' else 'external only'
            print('authenticated external clipboard:', mode, provider, 'OK')
        except Exception:
            time.sleep(0.05)
            log.flush()
            print('fixture agent exit:', agent.poll(), file=sys.stderr)
            print((Path(scratch) / 'agent.log').read_text(), file=sys.stderr)
            raise
        finally:
            agent.terminate()
            try:
                agent.wait(timeout=3)
            except subprocess.TimeoutExpired:
                agent.kill()
                agent.wait()
