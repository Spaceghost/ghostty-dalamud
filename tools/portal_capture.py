#!/usr/bin/env python3
"""Host-side portal session prototype. Does not yet deliver pixels to Ghostty.

Keep the D-Bus connection alive while consuming pipewire_fd. Closing this object
revokes capture and closes its FD; it never closes the captured application.
"""
import os
import uuid

PORTAL = 'org.freedesktop.portal.Desktop'
ROOT = '/org/freedesktop/portal/desktop'
SCREENCAST = 'org.freedesktop.portal.ScreenCast'
REMOTE_DESKTOP = 'org.freedesktop.portal.RemoteDesktop'
# USB HID page 7 -> Evdev, shared mapping with agent/wayland_keys.nelua.
HID_EVDEV = (0, 0, 0, 0, 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 28, 1, 14, 15, 57, 12, 13, 26, 27, 43, 43, 39, 40, 41, 51, 52, 53, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88, 99, 70, 119, 110, 102, 104, 111, 107, 109, 106, 105, 108, 103, 69, 98, 55, 74, 78, 96, 79, 80, 81, 75, 76, 77, 71, 72, 73, 82, 83, 86, 127, 116, 117, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194)


class PortalCapture:
    def __init__(self, transport):
        self.transport = transport
        self.session = None
        self.pipewire_fd = None
        self.stream = None
        self.closed_subscription = None
        self.revoked = False
        self.devices = 0
        self.wheel_remainder = [0, 0]
        self.held_keys = set()
        self.held_buttons = set()

    def start(self):
        if self.session is not None:
            raise RuntimeError('session already started')
        self.revoked = False
        try:
            created = self.transport.request('CreateSession', None)
            session = created.get('session_handle')
            if not isinstance(session, str) or not session.startswith(ROOT + '/session/'):
                raise RuntimeError('portal returned no valid session')
            self.session = session
            self.closed_subscription = self.transport.watch_closed(session, self._revoked)
            if getattr(self.transport, 'remote_input', False):
                self.transport.request('SelectDevices', session)
                if self.revoked:
                    raise RuntimeError('portal session was revoked')
            self.transport.request('SelectSources', session)
            if self.revoked:
                raise RuntimeError('portal session was revoked')
            started = self.transport.request('Start', session)
            if self.revoked:
                raise RuntimeError('portal session was revoked')
            granted = started.get('devices', 0)
            if not isinstance(granted, int) or isinstance(granted, bool) or granted < 0:
                raise RuntimeError('invalid granted device types')
            self.devices = granted & 3 if getattr(self.transport, 'remote_input', False) else 0
            streams = started.get('streams', [])
            if len(streams) != 1:
                raise RuntimeError('expected one selected window')
            node, props = streams[0]
            if not isinstance(node, int) or isinstance(node, bool) or node < 1:
                raise RuntimeError('invalid PipeWire node')
            if props.get('source_type', 2) != 2:
                raise RuntimeError('portal selected a non-window source')
            # Portal v6 avoids reusable node IDs; retain node for older portals.
            serial = props.get('pipewire-serial')
            self.stream = {'node': node, 'target': str(serial if serial is not None else node),
                           'properties': props}
            fd = self.transport.open_remote(session)
            if self.revoked:
                os.close(fd)
                raise RuntimeError('portal session was revoked')
            self.pipewire_fd = fd
            return self
        except BaseException:
            self.close()
            raise

    def pointer(self, event, frame_size):
        """Forward supported pointer events only after explicit POINTER grant."""
        import math
        if self.revoked or self.session is None or self.stream is None or not self.devices & 2:
            return False
        kind = event.get('kind')
        if kind not in ('move', 'button', 'wheel'):
            return False
        width, height = frame_size
        logical = self.stream['properties'].get('logical_size', self.stream['properties'].get('size', frame_size))
        if len(logical) != 2 or not all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v > 0
                                      for v in (*frame_size, *logical)):
            raise ValueError('invalid pointer coordinate space')
        x, y = event.get('x', 0), event.get('y', 0)
        if not all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in (x, y)):
            raise ValueError('invalid pointer coordinates')
        if kind == 'button' and (event.get('button') not in (0, 1, 2) or type(event.get('down')) is not bool):
            raise ValueError('invalid pointer button')
        if kind == 'wheel' and not all(type(event.get(axis, 0)) is int and abs(event.get(axis, 0)) <= 12000 for axis in ('dx', 'dy')):
            raise ValueError('invalid pointer wheel')
        lx = min(max(x, 0), max(width - 1, 0)) * logical[0] / width
        ly = min(max(y, 0), max(height - 1, 0)) * logical[1] / height
        self.transport.pointer_motion(self.session, self.stream['node'], lx, ly)
        if kind == 'button':
            button = 0x110 + event['button']
            self.transport.pointer_button(self.session, button, int(event['down']))
            if event['down']:
                self.held_buttons.add(button)
            else:
                self.held_buttons.discard(button)
        elif kind == 'wheel':
            # Preserve fractional notches until a complete discrete step accumulates.
            for axis, delta in ((1, event.get('dx', 0)), (0, -event.get('dy', 0))):
                self.wheel_remainder[axis] += delta
                steps = math.trunc(self.wheel_remainder[axis] / 120)
                if steps:
                    self.transport.pointer_axis(self.session, axis, steps)
                    self.wheel_remainder[axis] -= steps * 120
        return True

    def _key(self, code, down):
        self.transport.keyboard_keycode(self.session, code, int(down))
        if down:
            self.held_keys.add(code)
        else:
            self.held_keys.discard(code)

    def _modifiers(self, mods):
        for bit, code in ((1, 29), (2, 42), (4, 56), (8, 125)):
            down = bool(mods & bit)
            if down != (code in self.held_keys):
                self._key(code, down)

    def input(self, event, frame_size):
        if event.get('kind') in ('move', 'button', 'wheel'):
            return self.pointer(event, frame_size)
        if self.revoked or self.session is None or not self.devices & 1:
            return False
        kind = event.get('kind')
        if kind == 'key':
            hid, mods = event.get('hid'), event.get('mods', 0)
            if type(hid) is not int or type(mods) is not int or mods < 0 or mods > 15 or type(event.get('down')) is not bool:
                raise ValueError('invalid keyboard event')
            if 0xE0 <= hid <= 0xE7:
                return False # modifiers travel in the event mask
            code = HID_EVDEV[hid] if 0 <= hid < len(HID_EVDEV) else 0
            if not code:
                return False
            self._modifiers(mods)
            self._key(code, event['down'])
            if not event['down']:
                self._modifiers(0)
            return True
        if kind == 'text':
            text = event.get('text', '')
            if not isinstance(text, str) or len(text.encode('utf-8')) > 4096:
                raise ValueError('invalid keyboard text')
            specials = {10: 0xFF0D, 13: 0xFF0D, 9: 0xFF09, 8: 0xFF08}
            symbols = []
            for char in text:
                cp = ord(char)
                if cp in specials:
                    symbols.append(specials[cp])
                elif cp >= 32 and not 127 <= cp < 160:
                    symbols.append(cp if cp <= 255 else 0x01000000 | cp)
                else:
                    raise ValueError('unsupported control character')
            self._modifiers(0)
            for symbol in symbols:
                self.transport.keyboard_keysym(self.session, symbol, 1)
                self.transport.keyboard_keysym(self.session, symbol, 0)
            return True
        return False

    def _revoked(self):
        self.revoked = True
        self._cleanup(False)

    def close(self):
        self._cleanup(True)

    def _release_inputs(self, session):
        # A failed key release must not prevent releasing another held input.
        failure = None
        for notify, codes in ((self.transport.keyboard_keycode if self.held_keys else None, self.held_keys),
                              (self.transport.pointer_button if self.held_buttons else None, self.held_buttons)):
            for code in sorted(codes):
                try:
                    notify(session, code, 0)
                except Exception as error:
                    if failure is None:
                        failure = error
        if failure is not None:
            raise failure

    def _cleanup(self, notify_portal):
        session, self.session = self.session, None
        fd, self.pipewire_fd = self.pipewire_fd, None
        self.stream = None
        self.devices = 0
        subscription, self.closed_subscription = self.closed_subscription, None
        try:
            if subscription is not None:
                self.transport.unwatch_closed(subscription)
            if session is not None and notify_portal:
                try:
                    self._release_inputs(session)
                finally:
                    self.transport.close_session(session)
        finally:
            self.held_keys.clear()
            self.held_buttons.clear()
            self.wheel_remainder[:] = [0, 0]
            if fd is not None:
                os.close(fd)


class GioPortalTransport:
    def __init__(self, timeout_seconds=120, remote_input=False):
        import gi
        gi.require_version('Gio', '2.0')
        from gi.repository import Gio, GLib
        self.Gio, self.GLib = Gio, GLib
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.timeout_seconds = timeout_seconds
        self.remote_input = remote_input

    def request(self, method, session):
        Gio, GLib = self.Gio, self.GLib
        token = 'ghostty_' + uuid.uuid4().hex
        options = {'handle_token': GLib.Variant('s', token)}
        if method == 'CreateSession':
            options['session_handle_token'] = GLib.Variant('s', 'ghostty_' + uuid.uuid4().hex)
            args = GLib.Variant('(a{sv})', (options,))
        elif method == 'SelectDevices':
            if not self.remote_input:
                raise ValueError('input permission was not requested')
            options['types'] = GLib.Variant('u', 3)
            args = GLib.Variant('(oa{sv})', (session, options))
        elif method == 'SelectSources':
            # Explicit WINDOW only, single source, no persistent authorization.
            options.update(types=GLib.Variant('u', 2), multiple=GLib.Variant('b', False))
            args = GLib.Variant('(oa{sv})', (session, options))
        elif method == 'Start':
            args = GLib.Variant('(osa{sv})', (session, '', options))
        else:
            raise ValueError('unsupported portal method')
        responses = {}
        loop = GLib.MainLoop()
        expected = [None]
        def response(_bus, _sender, path, _interface, _signal, parameters):
            responses[path] = parameters.unpack()
            if path == expected[0]:
                loop.quit()
        subscription = self.bus.signal_subscribe(PORTAL, 'org.freedesktop.portal.Request', 'Response',
                                                None, None, Gio.DBusSignalFlags.NONE, response)
        timer = None
        try:
            interface = REMOTE_DESKTOP if self.remote_input and method != 'SelectSources' else SCREENCAST
            result = self.bus.call_sync(PORTAL, ROOT, interface, method, args, GLib.VariantType('(o)'),
                                        Gio.DBusCallFlags.NONE, 10000, None)
            path = expected[0] = result.unpack()[0]
            if path not in responses:
                def timeout():
                    loop.quit()
                    return False
                timer = GLib.timeout_add_seconds(self.timeout_seconds, timeout)
                loop.run()
            if path not in responses:
                # Cancel the outstanding request when the chooser times out.
                self.bus.call_sync(PORTAL, path, 'org.freedesktop.portal.Request', 'Close', None, None,
                                   Gio.DBusCallFlags.NONE, 10000, None)
                raise TimeoutError('portal selection timed out')
            code, payload = responses[path]
            if code != 0:
                raise RuntimeError('portal selection cancelled' if code == 1 else 'portal capture refused')
            return payload
        finally:
            self.bus.signal_unsubscribe(subscription)
            if timer is not None:
                # The timer may already have fired; avoid removing a dead source.
                source = GLib.MainContext.default().find_source_by_id(timer)
                if source is not None:
                    source.destroy()

    def open_remote(self, session):
        Gio, GLib = self.Gio, self.GLib
        result, fds = self.bus.call_with_unix_fd_list_sync(PORTAL, ROOT, SCREENCAST, 'OpenPipeWireRemote',
            GLib.Variant('(oa{sv})', (session, {})), GLib.VariantType('(h)'), Gio.DBusCallFlags.NONE,
            10000, None, None)
        return fds.get(result.unpack()[0])

    def close_session(self, session):
        self.bus.call_sync(PORTAL, session, 'org.freedesktop.portal.Session', 'Close', None, None,
                           self.Gio.DBusCallFlags.NONE, 10000, None)

    def _notify_pointer(self, method, signature, values):
        if not self.remote_input:
            raise RuntimeError('input permission was not requested')
        self.bus.call_sync(PORTAL, ROOT, REMOTE_DESKTOP, method,
            self.GLib.Variant(signature, values), None, self.Gio.DBusCallFlags.NONE, 2000, None)

    def pointer_motion(self, session, stream, x, y):
        self._notify_pointer('NotifyPointerMotionAbsolute', '(oa{sv}udd)', (session, {}, stream, x, y))

    def pointer_button(self, session, button, state):
        self._notify_pointer('NotifyPointerButton', '(oa{sv}iu)', (session, {}, button, state))

    def pointer_axis(self, session, axis, steps):
        self._notify_pointer('NotifyPointerAxisDiscrete', '(oa{sv}ui)', (session, {}, axis, steps))

    def keyboard_keycode(self, session, code, state):
        self._notify_pointer('NotifyKeyboardKeycode', '(oa{sv}iu)', (session, {}, code, state))

    def keyboard_keysym(self, session, symbol, state):
        self._notify_pointer('NotifyKeyboardKeysym', '(oa{sv}iu)', (session, {}, symbol, state))

    def watch_closed(self, session, callback):
        return self.bus.signal_subscribe(PORTAL, 'org.freedesktop.portal.Session', 'Closed',
            session, None, self.Gio.DBusSignalFlags.NONE,
            lambda *_args: callback())

    def unwatch_closed(self, subscription):
        self.bus.signal_unsubscribe(subscription)

    def pump(self):
        """Dispatch queued portal revocations; the future agent must call this regularly."""
        context = self.GLib.MainContext.default()
        while context.pending():
            context.iteration(False)


def pack_bgra(data, width, height, stride, offset=0):
    """Copy a bounded mapped BGRA buffer to tightly packed agent frame pixels."""
    if not (1 <= width <= 8192 and 1 <= height <= 8192) or stride < width * 4 or offset < 0:
        raise ValueError('invalid BGRA dimensions or stride')
    end = offset + (height - 1) * stride + width * 4
    if end > len(data):
        raise ValueError('truncated BGRA buffer')
    return b''.join(data[offset + y * stride:offset + y * stride + width * 4] for y in range(height))


class PipeWireFrames:
    """Nonblocking latest-frame reader. Call close before closing the portal session."""
    def __init__(self, capture):
        import gi
        gi.require_version('Gst', '1.0')
        gi.require_version('GstVideo', '1.0')
        from gi.repository import Gst, GstVideo
        Gst.init(None)
        if capture.pipewire_fd is None or capture.stream is None:
            raise RuntimeError('capture session is not active')
        self.Gst, self.GstVideo = Gst, GstVideo
        self.capture = capture
        self.serial = 0
        self.pipeline = Gst.parse_launch('pipewiresrc name=source ! videoconvert ! '
            'video/x-raw,format=BGRA ! appsink name=frames max-buffers=1 drop=true sync=false')
        source = self.pipeline.get_by_name('source')
        source.set_property('fd', capture.pipewire_fd)
        if 'pipewire-serial' in capture.stream['properties']:
            source.set_property('target-object', capture.stream['target'])
        else:
            # Old portal node IDs are paths, not serials.
            source.set_property('path', str(capture.stream['node']))
        self.sink = self.pipeline.get_by_name('frames')
        if self.pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            self.close()
            raise RuntimeError('PipeWire pipeline failed to start')

    def frame(self):
        self.capture.transport.pump()
        if self.capture.revoked or self.capture.pipewire_fd is None:
            self.close()
            raise RuntimeError('portal capture ended')
        if self.pipeline is None:
            raise RuntimeError('frame reader is closed')
        Gst = self.Gst
        message = self.pipeline.get_bus().pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.EOS)
        if message is not None:
            self.close()
            raise RuntimeError(str(message.parse_error()[0]) if message.type == Gst.MessageType.ERROR else 'PipeWire stream ended')
        sample = self.sink.emit('try-pull-sample', 0)
        if sample is None:
            return None
        info = self.GstVideo.VideoInfo.new_from_caps(sample.get_caps())
        buffer = sample.get_buffer()
        meta = self.GstVideo.buffer_get_video_meta(buffer)
        stride = meta.stride[0] if meta is not None else info.stride[0]
        offset = meta.offset[0] if meta is not None else info.offset[0]
        mapped, view = buffer.map(Gst.MapFlags.READ)
        if not mapped:
            raise RuntimeError('could not map PipeWire frame')
        try:
            pixels = pack_bgra(view.data, info.width, info.height, stride, offset)
        finally:
            buffer.unmap(view)
        self.serial += 1
        return {'pixels': pixels, 'w': info.width, 'h': info.height,
                'stride': info.width * 4, 'serial': self.serial}

    def close(self):
        pipeline, self.pipeline = self.pipeline, None
        if pipeline is not None:
            pipeline.set_state(self.Gst.State.NULL)


# Private helper-to-agent transport, distinct from the public Ghostty protocol.
# Header: magic, width, height, serial, payload bytes (little endian).
# EOF ends capture. Frames are packed BGRA, top-down, with alpha ignored by agent.
import struct
FRAME_HEADER = struct.Struct('<4sIIQI')
MAX_FRAME_BYTES = 8192 * 8192 * 4


def encode_frame(frame):
    pixels = frame['pixels']
    width, height, serial = frame['w'], frame['h'], frame['serial']
    if not (1 <= width <= 8192 and 1 <= height <= 8192 and 1 <= serial < 2**64):
        raise ValueError('invalid portal frame header')
    if frame['stride'] != width * 4 or len(pixels) != width * height * 4:
        raise ValueError('portal frame must be packed BGRA')
    return FRAME_HEADER.pack(b'PGF1', width, height, serial, len(pixels)), pixels


def receive_frame(connection):
    def exact(size, clean_eof=False):
        parts = bytearray()
        while len(parts) < size:
            chunk = connection.recv(min(size - len(parts), 65536))
            if not chunk:
                if clean_eof and not parts:
                    return None
                raise EOFError('truncated portal frame')
            parts.extend(chunk)
        return parts
    header = exact(FRAME_HEADER.size, clean_eof=True)
    if header is None:
        return None
    magic, width, height, serial, size = FRAME_HEADER.unpack(header)
    if magic != b'PGF1' or not (1 <= width <= 8192 and 1 <= height <= 8192 and serial > 0) \
            or size != width * height * 4 or size > MAX_FRAME_BYTES:
        raise ValueError('invalid portal frame header')
    pixels = exact(size)
    return {'w': width, 'h': height, 'stride': width * 4, 'serial': serial, 'pixels': bytes(pixels)}


# Private agent-to-helper input framing; fixed header plus bounded UTF-8 text.
INPUT_HEADER = struct.Struct('<4sBBHiiiiiHH')


class InputDecoder:
    def __init__(self):
        self.buffer = bytearray()
        self.failed = False

    def feed(self, data):
        if self.failed:
            raise ValueError('input decoder is failed')
        try:
            if len(self.buffer) + len(data) > 65536:
                raise ValueError('input queue exceeded limit')
            self.buffer.extend(data)
            events = []
            while len(self.buffer) >= INPUT_HEADER.size:
                magic, kind, down, hid, x, y, button, dx, dy, mods, length = INPUT_HEADER.unpack_from(self.buffer)
                if magic != b'PGI1' or kind not in range(1, 7) or down not in (0, 1) or mods > 255 or length > 4096:
                    raise ValueError('invalid input header')
                if kind != 5 and length != 0:
                    raise ValueError('text payload only belongs to text events')
                size = INPUT_HEADER.size + length
                if len(self.buffer) < size:
                    break
                text = bytes(self.buffer[INPUT_HEADER.size:size]).decode('utf-8')
                del self.buffer[:size]
                events.append(dict(kind=('move', 'button', 'wheel', 'key', 'text', 'focus')[kind - 1],
                    down=bool(down), hid=hid, x=x, y=y, button=button, dx=dx, dy=dy, mods=mods, text=text))
            return events
        except (ValueError, UnicodeError):
            self.failed = True
            self.buffer.clear()
            raise

    def eof(self):
        if self.buffer:
            self.failed = True
            raise EOFError('truncated input event')


def poll_inputs(connection, decoder):
    import select
    if not select.select([connection], [], [], 0)[0]:
        return []
    data = connection.recv(65536)
    if not data:
        decoder.eof()
        raise EOFError('agent disconnected')
    return decoder.feed(data)


def serve_frames(connection, reader, stopped=lambda: False, on_input=None):
    """One reader and a bounded socket writer; a stalled/dead agent ends capture."""
    import time
    connection.settimeout(2)
    decoder = InputDecoder()
    frame_size = None
    while not stopped():
        frame = reader.frame()
        if frame is not None:
            frame_size = (frame['w'], frame['h'])
            header, pixels = encode_frame(frame)
            connection.sendall(header)
            connection.sendall(pixels)
        else:
            time.sleep(0.01)
        for event in poll_inputs(connection, decoder):
            if on_input is not None and frame_size is not None:
                on_input(event, frame_size)


def main():
    import argparse
    import socket
    import signal
    def terminate(_signum, _frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate)
    parser = argparse.ArgumentParser(description='Experimental portal capture helper for ghostty-agent')
    parser.add_argument('--socket-fd', type=int, required=True, help='Inherited private Unix stream socket to the parent agent')
    parser.add_argument('--input', action='store_true', help='Request Remote Desktop pointer/keyboard consent')
    args = parser.parse_args()
    capture = None
    reader = None
    with socket.socket(fileno=args.socket_fd) as connection:
        if connection.family != socket.AF_UNIX or connection.type != socket.SOCK_STREAM:
            raise ValueError('expected a private Unix stream socket')
        try:
            capture = PortalCapture(GioPortalTransport(remote_input=args.input)).start()
            reader = PipeWireFrames(capture)
            serve_frames(connection, reader, on_input=capture.input if args.input else None)
        finally:
            if reader is not None:
                reader.close()
            if capture is not None:
                capture.close()


if __name__ == '__main__':
    main()
