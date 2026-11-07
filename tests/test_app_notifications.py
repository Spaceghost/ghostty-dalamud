#!/usr/bin/env python3
"""Private D-Bus fixture, synthetic notifications only."""
import asyncio
import importlib.util
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import unittest
from urllib.parse import unquote

from dbus_next import Variant
from dbus_next.aio import MessageBus

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('app_notifications', ROOT / 'tools/app_notifications.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StoreTests(unittest.TestCase):
    def test_replacement_and_close(self):
        events = []
        store = module.NotificationStore(events.append)
        ident = store.notify('fixture', 0, 'first', 'body')
        self.assertEqual(ident, store.notify('fixture', ident, 'replacement', 'new'))
        self.assertEqual(len(store.active), 1)
        self.assertTrue(store.close(ident))
        self.assertFalse(store.close(ident))
        self.assertEqual(events[-1], {'kind': 'closed', 'id': ident})

    def test_bounded_text_and_retention(self):
        events = []
        store = module.NotificationStore(events.append)
        store.notify('x' * 500, 0, '日' * 1000, '\0' + '✓' * 5000)
        event = events[-1]
        self.assertLessEqual(len(event['summary'].encode()), 512)
        self.assertLessEqual(len(event['body'].encode()), 4096)
        self.assertNotIn('\0', event['body'])
        for _ in range(100):
            store.notify('fixture', 0, 'message', '')
        self.assertEqual(len(store.active), 64)


class PrivateBusTests(unittest.IsolatedAsyncioTestCase):
    async def test_notify_replace_close_and_disconnect(self):
        parent, child = socket.socketpair()
        parent.setblocking(False)
        helper = subprocess.Popen([sys.executable, str(ROOT / 'tools/app_notifications.py'),
                                   '--socket-fd', str(child.fileno())], pass_fds=[child.fileno()],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        child.close()
        bus = None
        loop = asyncio.get_running_loop()

        async def exact(size):
            body = bytearray()
            while len(body) < size:
                chunk = await asyncio.wait_for(loop.sock_recv(parent, size - len(body)), 3)
                if not chunk:
                    raise EOFError('helper disconnected')
                body.extend(chunk)
            return bytes(body)

        async def event():
            size, = struct.unpack('<I', await exact(4))
            self.assertLessEqual(size, 32769)
            payload = await exact(size)
            if payload[0] == 1:
                return {'kind': 'ready', 'address': payload[1:].decode()}
            self.assertEqual(payload[0], 2)
            return json.loads(payload[1:])

        try:
            ready = await event()
            self.assertEqual(ready['kind'], 'ready')
            bus = await MessageBus(bus_address=ready['address']).connect()
            tree = await bus.introspect('org.freedesktop.Notifications', '/org/freedesktop/Notifications')
            obj = bus.get_proxy_object('org.freedesktop.Notifications', '/org/freedesktop/Notifications', tree)
            notifications = obj.get_interface('org.freedesktop.Notifications')
            self.assertEqual(await notifications.call_get_capabilities(), ['body'])
            self.assertEqual((await notifications.call_get_server_information())[-1], '1.2')
            ident = await notifications.call_notify('Fixture app', 0, '/untrusted/icon', 'Synthetic title',
                                                   'Synthetic body', [], {'desktop-entry': Variant('s', 'fixture.desktop')}, -1)
            received = await event()
            self.assertEqual(received['id'], ident)
            self.assertEqual(received['desktop_entry'], 'fixture.desktop')
            self.assertEqual(received['body'], 'Synthetic body')
            self.assertNotIn('icon', received)
            replacement = await notifications.call_notify('Fixture app', ident, '', 'Replaced', '\x01' * 4096,
                                                         [], {}, -1)
            self.assertEqual(replacement, ident)
            self.assertEqual((await event())['summary'], 'Replaced')
            await notifications.call_close_notification(ident)
            self.assertEqual(await event(), {'kind': 'closed', 'id': ident})
            bus.disconnect()
            bus = None
            parent.close()
            self.assertEqual(await asyncio.to_thread(helper.wait, 3), 0)
            fields = dict(part.split('=', 1) for part in ready['address'].removeprefix('unix:').split(','))
            endpoint = unquote(fields['path']) if 'path' in fields else '\0' + unquote(fields['abstract'])
            with socket.socket(socket.AF_UNIX) as probe, self.assertRaises(OSError):
                probe.connect(endpoint)
        finally:
            if bus:
                bus.disconnect()
            parent.close()
            if helper.poll() is None:
                try:
                    await asyncio.to_thread(helper.wait, 1)
                except subprocess.TimeoutExpired:
                    helper.terminate()
                    await asyncio.to_thread(helper.wait, 3)
            stderr = helper.stderr.read().decode()
            helper.stderr.close()
            if helper.returncode:
                self.fail('notification helper failed: ' + stderr)


if __name__ == '__main__':
    unittest.main()
