#!/usr/bin/env python3
"""Synthetic notification from an app launched by the private compositor."""
import asyncio
import os
from pathlib import Path
import sys

from dbus_next import Variant
from dbus_next.aio import MessageBus


async def main():
    address = os.environ['DBUS_SESSION_BUS_ADDRESS']
    bus = await MessageBus(bus_address=address).connect()
    try:
        tree = await bus.introspect('org.freedesktop.Notifications', '/org/freedesktop/Notifications')
        obj = bus.get_proxy_object('org.freedesktop.Notifications', '/org/freedesktop/Notifications', tree)
        notifications = obj.get_interface('org.freedesktop.Notifications')
        count = int(sys.argv[2]) if len(sys.argv) > 2 else 1
        assert 1 <= count <= 64
        for index in range(count):
            summary = 'Synthetic compositor message' + (f' #{index}' if count > 1 else '')
            ident = await notifications.call_notify('Fixture app', 0, '', summary,
                                                   'Synthetic notification body', [],
                                                   {'desktop-entry': Variant('s', 'fixture.desktop')}, -1)
        Path(sys.argv[1]).write_text(address + '\n' + str(ident) + '\n')
    finally:
        bus.disconnect()


asyncio.run(main())
