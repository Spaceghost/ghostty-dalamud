#!/usr/bin/env python3
"""Private compositor-app notification bus; bounded events over an inherited FD.

Never claims the user's desktop bus. The native owner receives the new address
and gives it only to apps it launches inside its compositor.
"""
import argparse
import asyncio
from collections import OrderedDict
import json
import signal
import socket
import struct

from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, method, signal as dbus_signal


def bounded_text(value, limit):
    if not isinstance(value, str):
        return ''
    return value.replace('\0', '').encode('utf-8', errors='replace')[:limit].decode('utf-8', errors='ignore')


class NotificationStore:
    def __init__(self, emit):
        self.emit = emit
        self.active = OrderedDict()
        self.next_id = 1

    def notify(self, app, replacement, summary, body, desktop_entry='', urgency=1):
        ident = replacement if replacement in self.active else self.next_id
        if ident == self.next_id:
            self.next_id = self.next_id % 0xffffffff + 1
            while self.next_id in self.active:
                self.next_id = self.next_id % 0xffffffff + 1
        event = {'kind': 'notification', 'id': ident, 'app': bounded_text(app, 256),
                 'desktop_entry': bounded_text(desktop_entry, 256),
                 'summary': bounded_text(summary, 512), 'body': bounded_text(body, 4096),
                 'urgency': urgency if urgency in (0, 1, 2) else 1}
        self.active.pop(ident, None)
        self.active[ident] = event
        while len(self.active) > 64:
            self.active.popitem(last=False)
        self.emit(event)
        return ident

    def close(self, ident):
        if self.active.pop(ident, None) is None:
            return False
        self.emit({'kind': 'closed', 'id': ident})
        return True


class Notifications(ServiceInterface):
    def __init__(self, store):
        super().__init__('org.freedesktop.Notifications')
        self.store = store

    @method()
    def GetCapabilities(self) -> 'as':
        return ['body']

    @method()
    def GetServerInformation(self) -> 'ssss':
        return ['Ghostty Compositor', 'Spaceghost', '1', '1.2']

    @method()
    def Notify(self, app_name: 's', replaces_id: 'u', app_icon: 's', summary: 's', body: 's',
               actions: 'as', hints: 'a{sv}', expire_timeout: 'i') -> 'u':
        desktop = hints.get('desktop-entry')
        urgency = hints.get('urgency')
        return self.store.notify(app_name, replaces_id, summary, body,
                                 desktop.value if desktop and desktop.signature == 's' else '',
                                 urgency.value if urgency and urgency.signature == 'y' else 1)

    @method()
    def CloseNotification(self, ident: 'u'):
        if self.store.close(ident):
            self.NotificationClosed(ident, 3)

    @dbus_signal()
    def NotificationClosed(self, ident: 'u', reason: 'u') -> 'uu':
        return [ident, reason]


async def serve(fd):
    channel = socket.socket(fileno=fd)
    channel.setblocking(False)
    loop = asyncio.get_running_loop()
    daemon = None
    bus = None
    tasks = []
    stopped = asyncio.Event()
    queue = asyncio.Queue(maxsize=64)

    def emit(event):
        if queue.full():
            queue.get_nowait()
        queue.put_nowait(event)

    async def send(event):
        payload = (b'\x01' + event['address'].encode('utf-8') if event['kind'] == 'ready'
                   else b'\x02' + json.dumps(event, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
        if len(payload) > 32769:
            raise ValueError('notification frame exceeds limit')
        await loop.sock_sendall(channel, struct.pack('<I', len(payload)) + payload)

    async def forward():
        while True:
            await send(await queue.get())

    async def parent():
        while await loop.sock_recv(channel, 1):
            pass

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stopped.set)
    try:
        daemon = await asyncio.create_subprocess_exec('dbus-daemon', '--session', '--nofork', '--print-address=1',
                                                     stdout=asyncio.subprocess.PIPE,
                                                     stderr=asyncio.subprocess.DEVNULL)
        address = (await asyncio.wait_for(daemon.stdout.readline(), 2)).decode().strip()
        if not address or len(address) > 1024:
            raise RuntimeError('private bus did not return an address')
        bus = await MessageBus(bus_address=address).connect()
        bus.export('/org/freedesktop/Notifications', Notifications(NotificationStore(emit)))
        await bus.request_name('org.freedesktop.Notifications')
        await send({'kind': 'ready', 'address': address})
        tasks = [asyncio.create_task(forward()), asyncio.create_task(parent()),
                 asyncio.create_task(stopped.wait()), asyncio.create_task(daemon.wait())]
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    finally:
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        if bus:
            bus.disconnect()
        if daemon and daemon.returncode is None:
            daemon.terminate()
            try:
                await asyncio.wait_for(daemon.wait(), 1)
            except asyncio.TimeoutError:
                daemon.kill()
                await daemon.wait()
        channel.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--socket-fd', required=True, type=int)
    arguments = parser.parse_args()
    asyncio.run(serve(arguments.socket_fd))
