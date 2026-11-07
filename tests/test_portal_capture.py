import importlib.util
import os
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('portal_capture', Path(__file__).parents[1] / 'tools/portal_capture.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Transport:
    def __init__(self, streams=None):
        self.calls = []
        self.streams = streams if streams is not None else [(42, {'source_type': 2, 'pipewire-serial': 123456})]
        self.fd = None

    def watch_closed(self, session, callback):
        self.closed = callback
        return 7

    def unwatch_closed(self, subscription):
        self.unwatched = subscription

    def request(self, method, session):
        self.calls.append((method, session))
        return {'session_handle': module.ROOT + '/session/test/one'} if method == 'CreateSession' else {'streams': self.streams}

    def open_remote(self, session):
        self.calls.append(('remote', session))
        self.fd = os.open('/dev/null', os.O_RDONLY)
        return self.fd

    def close_session(self, session):
        self.calls.append(('close', session))


class PortalCaptureTests(unittest.TestCase):
    def test_keyboard_grant_modifiers_hid_and_close_release(self):
        transport = Transport()
        calls = []
        transport.keyboard_keycode = lambda *args: calls.append(args[1:])
        capture = module.PortalCapture(transport).start()
        try:
            event = dict(kind='key', hid=4, mods=3, down=True)
            self.assertFalse(capture.input(event, (1, 1)))
            capture.devices = 1
            self.assertTrue(capture.input(event, (1, 1)))
            self.assertEqual([(29, 1), (42, 1), (30, 1)], calls)
            self.assertFalse(capture.input(dict(kind='key', hid=999, mods=0, down=True), (1, 1)))
            self.assertFalse(capture.input(dict(kind='key', hid=0xE0, mods=1, down=True), (1, 1)))
        finally:
            capture.close()
        self.assertEqual({(29, 0), (42, 0), (30, 0)}, set(calls[3:]))
        self.assertFalse(capture.input(event, (1, 1)))

    def test_unicode_text_and_controls_are_dispatched_or_refused_atomically(self):
        transport = Transport()
        calls = []
        transport.keyboard_keysym = lambda *args: calls.append(args[1:])
        transport.keyboard_keycode = lambda *args: None
        capture = module.PortalCapture(transport).start()
        capture.devices = 1
        try:
            self.assertTrue(capture.input(dict(kind='text', text='é猫\n'), (1, 1)))
            self.assertEqual([(233, 1), (233, 0), (0x0100732B, 1), (0x0100732B, 0), (0xFF0D, 1), (0xFF0D, 0)], calls)
            before = list(calls)
            with self.assertRaises(ValueError):
                capture.input(dict(kind='text', text='valid\x00'), (1, 1))
            self.assertEqual(before, calls)
        finally:
            capture.close()

    def test_fragmented_input_decoder_and_socket_delivery(self):
        import socket
        header = module.INPUT_HEADER.pack(b'PGI1', 2, 1, 0, 10, 20, 1, 0, 0, 0, 0)
        decoder = module.InputDecoder()
        for byte in header[:-1]:
            self.assertEqual([], decoder.feed(bytes([byte])))
        event = decoder.feed(header[-1:])[0]
        self.assertEqual(('button', True, 10, 20, 1), (event['kind'], event['down'], event['x'], event['y'], event['button']))
        left, right = socket.socketpair()
        try:
            self.assertEqual([], module.poll_inputs(right, decoder))
            left.sendall(header)
            self.assertEqual(event, module.poll_inputs(right, decoder)[0])
            left.shutdown(socket.SHUT_WR)
            with self.assertRaises(EOFError):
                module.poll_inputs(right, decoder)
        finally:
            left.close()
            right.close()

    def test_input_decoder_rejects_bad_headers_and_truncation(self):
        for magic, kind, size in [(b'BAD!', 1, 0), (b'PGI1', 7, 0), (b'PGI1', 5, 4097), (b'PGI1', 1, 4)]:
            decoder = module.InputDecoder()
            with self.assertRaises(ValueError):
                decoder.feed(module.INPUT_HEADER.pack(magic, kind, 0, 0, 0, 0, 0, 0, 0, 0, size))
            self.assertTrue(decoder.failed)
            with self.assertRaises(ValueError):
                decoder.feed(b'')
        decoder = module.InputDecoder()
        decoder.feed(b'PG')
        with self.assertRaises(EOFError):
            decoder.eof()

    def test_pointer_grants_coordinate_scaling_buttons_and_scroll(self):
        transport = Transport([(42, {'logical_size': (100, 50)})])
        calls = []
        transport.pointer_motion = lambda *args: calls.append(('move', args))
        transport.pointer_button = lambda *args: calls.append(('button', args))
        transport.pointer_axis = lambda *args: calls.append(('axis', args))
        capture = module.PortalCapture(transport).start()
        try:
            self.assertFalse(capture.pointer({'kind': 'move', 'x': 100, 'y': 50}, (200, 100)))
            capture.devices = 2
            self.assertTrue(capture.pointer({'kind': 'button', 'x': 100, 'y': 50, 'button': 1, 'down': True}, (200, 100)))
            self.assertEqual((42, 50.0, 25.0), calls[0][1][1:])
            self.assertEqual((0x111, 1), calls[1][1][1:])
            capture.pointer({'kind': 'wheel', 'dx': 60, 'dy': 120}, (200, 100))
            self.assertEqual((0, -1), calls[-1][1][1:])
            capture.pointer({'kind': 'wheel', 'dx': 60}, (200, 100))
            self.assertEqual((1, 1), calls[-1][1][1:])
            with self.assertRaises(ValueError):
                capture.pointer({'kind': 'button', 'button': 8, 'down': True}, (200, 100))
            with self.assertRaises(ValueError):
                capture.pointer({'kind': 'move', 'x': float('nan')}, (200, 100))
            capture.devices = 1
            self.assertFalse(capture.pointer({'kind': 'move'}, (200, 100)))
        finally:
            capture.close()
        self.assertFalse(capture.pointer({'kind': 'move'}, (200, 100)))

    def test_close_releases_held_pointer_buttons_before_closing_session(self):
        transport = Transport()
        calls = []
        transport.pointer_motion = lambda *args: None
        transport.pointer_button = lambda session, button, state: calls.append((button, state))
        original_close = transport.close_session
        def close(session):
            calls.append('close')
            original_close(session)
        transport.close_session = close
        capture = module.PortalCapture(transport).start()
        capture.devices = 2
        capture.pointer({'kind': 'button', 'button': 0, 'down': True}, (200, 100))
        capture.pointer({'kind': 'button', 'button': 1, 'down': True}, (200, 100))
        capture.pointer({'kind': 'button', 'button': 1, 'down': False}, (200, 100))
        capture.close()
        capture.close()
        self.assertEqual([(0x110, 1), (0x111, 1), (0x111, 0), (0x110, 0), 'close'], calls)
        self.assertEqual(set(), capture.held_buttons)

    def test_revocation_discards_held_buttons_without_notifying_closed_portal(self):
        transport = Transport()
        calls = []
        transport.pointer_motion = lambda *args: None
        transport.pointer_button = lambda *args: calls.append(args)
        capture = module.PortalCapture(transport).start()
        capture.devices = 2
        capture.pointer({'kind': 'button', 'button': 0, 'down': True}, (200, 100))
        capture._revoked()
        capture.close()
        self.assertEqual(1, len(calls))
        self.assertEqual(set(), capture.held_buttons)

    def test_failed_key_release_still_releases_buttons_and_closes_session(self):
        transport = Transport()
        released = []
        def key(session, code, state):
            released.append(('key', code))
            if code == 29:
                raise RuntimeError('release refused')
        transport.keyboard_keycode = key
        transport.pointer_button = lambda session, code, state: released.append(('button', code))
        capture = module.PortalCapture(transport).start()
        capture.held_keys.update((29, 42))
        capture.held_buttons.add(0x110)
        with self.assertRaisesRegex(RuntimeError, 'release refused'):
            capture.close()
        self.assertEqual([('key', 29), ('key', 42), ('button', 0x110)], released)
        self.assertIn('close', [call[0] for call in transport.calls])
        self.assertIsNone(capture.session)
        self.assertEqual(set(), capture.held_keys)
        self.assertEqual(set(), capture.held_buttons)
        capture.close()

    def test_gio_transport_uses_remote_session_methods_and_screencast_sources(self):
        try:
            import gi
            gi.require_version('Gio', '2.0')
            from gi.repository import Gio, GLib
        except (ImportError, ValueError):
            self.skipTest('Gio introspection not installed')
        class Bus:
            def __init__(self):
                self.calls = []
            def signal_subscribe(self, *args):
                self.callback = args[-1]
                return 1
            def signal_unsubscribe(self, subscription):
                pass
            def call_sync(self, bus, root, interface, method, args, *unused):
                self.calls.append((interface, method, args.unpack()))
                path = module.ROOT + '/request/test/one'
                self.callback(self, None, path, None, None, GLib.Variant('(ua{sv})', (0, {})))
                return GLib.Variant('(o)', (path,))
        transport = module.GioPortalTransport.__new__(module.GioPortalTransport)
        transport.Gio, transport.GLib = Gio, GLib
        transport.bus = Bus()
        transport.remote_input = True
        transport.timeout_seconds = 1
        session = module.ROOT + '/session/test/one'
        for method in ['CreateSession', 'SelectDevices', 'SelectSources', 'Start']:
            transport.request(method, session)
        self.assertEqual([module.REMOTE_DESKTOP, module.REMOTE_DESKTOP, module.SCREENCAST, module.REMOTE_DESKTOP],
                         [call[0] for call in transport.bus.calls])
        self.assertEqual(3, transport.bus.calls[1][2][-1]['types'])
        self.assertEqual(2, transport.bus.calls[2][2][-1]['types'])
        self.assertFalse(transport.bus.calls[2][2][-1]['multiple'])
        self.assertNotIn('persist_mode', transport.bus.calls[1][2][-1])

    def test_remote_input_negotiates_devices_and_retains_only_granted_types(self):
        transport = Transport()
        transport.remote_input = True
        original = transport.request
        def request(method, session):
            payload = original(method, session)
            if method == 'Start':
                payload['devices'] = 2 # pointer only, no keyboard permission
            return payload
        transport.request = request
        capture = module.PortalCapture(transport).start()
        try:
            self.assertEqual(['CreateSession', 'SelectDevices', 'SelectSources', 'Start', 'remote'], [c[0] for c in transport.calls])
            self.assertEqual(2, capture.devices)
        finally:
            capture.close()
        self.assertEqual(0, capture.devices)

    def test_screencast_session_never_grants_input(self):
        transport = Transport()
        original = transport.request
        def request(method, session):
            payload = original(method, session)
            payload['devices'] = 3
            return payload
        transport.request = request
        capture = module.PortalCapture(transport).start()
        try:
            self.assertEqual(0, capture.devices)
        finally:
            capture.close()

    def test_sender_loop_delivers_frames_and_stops(self):
        import socket
        from types import SimpleNamespace
        frames = [dict(w=1, h=1, stride=4, serial=i, pixels=b'BGRA') for i in (1, 2)]
        remaining = iter(frames)
        sent = [0]
        def frame():
            sent[0] += 1
            return next(remaining)
        left, right = socket.socketpair()
        try:
            inputs = []
            right.sendall(module.INPUT_HEADER.pack(b'PGI1', 1, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            module.serve_frames(left, SimpleNamespace(frame=frame), lambda: sent[0] == 2,
                lambda event, size: inputs.append((event['kind'], size)))
            self.assertEqual([('move', (1, 1))], inputs)
            self.assertEqual(frames[0], module.receive_frame(right))
            self.assertEqual(frames[1], module.receive_frame(right))
            self.assertEqual(2, sent[0])
        finally:
            left.close()
            right.close()

    def test_frame_transport_handles_fragmented_bytes_and_clean_eof(self):
        import socket
        frame = {'w': 1, 'h': 1, 'stride': 4, 'serial': 17, 'pixels': b'BGRA'}
        header, pixels = module.encode_frame(frame)
        left, right = socket.socketpair()
        try:
            for byte in header + pixels:
                left.sendall(bytes([byte]))
            left.shutdown(socket.SHUT_WR)
            self.assertEqual(frame, module.receive_frame(right))
            self.assertIsNone(module.receive_frame(right))
        finally:
            left.close()
            right.close()

    def test_frame_transport_rejects_invalid_header_before_reading_payload(self):
        import socket
        for header in [module.FRAME_HEADER.pack(b'BAD!', 1, 1, 1, 4),
                       module.FRAME_HEADER.pack(b'PGF1', 8193, 1, 1, 32772),
                       module.FRAME_HEADER.pack(b'PGF1', 1, 1, 1, 999999)]:
            left, right = socket.socketpair()
            try:
                left.sendall(header)
                with self.assertRaises(ValueError):
                    module.receive_frame(right)
            finally:
                left.close()
                right.close()

    def test_frame_transport_distinguishes_truncation_from_clean_eof(self):
        import socket
        left, right = socket.socketpair()
        try:
            left.sendall(module.FRAME_HEADER.pack(b'PGF1', 1, 1, 1, 4) + b'BG')
            left.shutdown(socket.SHUT_WR)
            with self.assertRaises(EOFError):
                module.receive_frame(right)
        finally:
            left.close()
            right.close()

    def test_real_gstreamer_buffer_mapping_with_synthetic_source(self):
        try:
            import gi
            gi.require_version('Gst', '1.0')
            gi.require_version('GstVideo', '1.0')
            from gi.repository import Gst, GstVideo
        except (ImportError, ValueError):
            self.skipTest('GStreamer introspection not installed')
        import time
        from types import SimpleNamespace
        Gst.init(None)
        if not Gst.ElementFactory.find('videotestsrc') or not Gst.ElementFactory.find('appsink'):
            self.skipTest('GStreamer test elements not installed')
        reader = module.PipeWireFrames.__new__(module.PipeWireFrames)
        reader.Gst, reader.GstVideo = Gst, GstVideo
        reader.capture = SimpleNamespace(revoked=False, pipewire_fd=0, transport=SimpleNamespace(pump=lambda: None))
        reader.serial = 0
        reader.pipeline = Gst.parse_launch('videotestsrc is-live=true pattern=black ! video/x-raw,format=BGRA,width=2,height=2 ! appsink name=frames max-buffers=1 drop=true sync=false')
        reader.sink = reader.pipeline.get_by_name('frames')
        reader.pipeline.set_state(Gst.State.PLAYING)
        try:
            deadline = time.monotonic() + 3
            frame = None
            while frame is None and time.monotonic() < deadline:
                frame = reader.frame()
                time.sleep(0.01)
            self.assertIsNotNone(frame)
            self.assertEqual((2, 2, 8, 1), (frame['w'], frame['h'], frame['stride'], frame['serial']))
            self.assertEqual(bytes([0, 0, 0, 255]) * 4, frame['pixels'])
        finally:
            reader.close()

    def test_bgra_padding_and_offset_are_removed(self):
        self.assertEqual(b'abcdefgh', module.pack_bgra(b'xxabcdPAD!efgh', 1, 2, 8, 2))

    def test_invalid_and_truncated_frames_are_refused(self):
        for args in [(b'', 1, 1, 4), (b'1234', 1, 1, 3), (b'1234', 0, 1, 4),
                     (b'1234', 1, 1, 4, -1), (b'', 8193, 1, 40000)]:
            with self.assertRaises(ValueError):
                module.pack_bgra(*args)

    def test_session_order_serial_and_fd_cleanup(self):
        transport = Transport()
        capture = module.PortalCapture(transport).start()
        self.assertEqual(['CreateSession', 'SelectSources', 'Start', 'remote'], [c[0] for c in transport.calls])
        self.assertEqual('123456', capture.stream['target'])
        fd = capture.pipewire_fd
        capture.close()
        with self.assertRaises(OSError):
            os.fstat(fd)
        capture.close()
        self.assertEqual(1, sum(c[0] == 'close' for c in transport.calls))

    def test_monitor_or_multiple_selection_revokes_session(self):
        for streams in [[(1, {'source_type': 1})], [(1, {}), (2, {})], []]:
            transport = Transport(streams)
            with self.assertRaises(RuntimeError):
                module.PortalCapture(transport).start()
            self.assertEqual('close', transport.calls[-1][0])
            self.assertIsNone(transport.fd)

    def test_revocation_closes_fd_without_calling_closed_session(self):
        transport = Transport()
        capture = module.PortalCapture(transport).start()
        fd = capture.pipewire_fd
        transport.closed()
        self.assertTrue(capture.revoked)
        self.assertIsNone(capture.stream)
        self.assertIsNone(capture.session)
        self.assertEqual(7, transport.unwatched)
        with self.assertRaises(OSError):
            os.fstat(fd)
        capture.close()
        self.assertFalse(any(c[0] == 'close' for c in transport.calls))

    def test_revocation_during_remote_open_does_not_leak_fd(self):
        transport = Transport()
        original = transport.open_remote
        def remote(session):
            fd = original(session)
            transport.closed()
            return fd
        transport.open_remote = remote
        with self.assertRaisesRegex(RuntimeError, 'revoked'):
            module.PortalCapture(transport).start()
        with self.assertRaises(OSError):
            os.fstat(transport.fd)

    def test_old_portal_uses_node_and_double_start_is_refused(self):
        transport = Transport([(22, {})])
        capture = module.PortalCapture(transport).start()
        try:
            self.assertEqual('22', capture.stream['target'])
            with self.assertRaises(RuntimeError):
                capture.start()
        finally:
            capture.close()


if __name__ == '__main__':
    unittest.main()
