#!/usr/bin/env python3
"""Real GTK clipboard source for the private compositor integration fixture.

Enter publishes an offer; the request log proves whether data was requested.
Uses ctypes so the fixture needs GTK runtime libraries but no GI/devel package.
GTK contract: https://docs.gtk.org/gtk3/method.Clipboard.set_with_data.html
"""
import ctypes as c
from pathlib import Path
import sys

gtk = c.CDLL("libgtk-3.so.0")
gobject = c.CDLL("libgobject-2.0.so.0")
gdk = c.CDLL("libgdk-3.so.0")
ptr = c.c_void_p


def bind(lib, name, result, *args):
    fn = getattr(lib, name)
    fn.restype = result
    fn.argtypes = args
    return fn


class Target(c.Structure):
    _fields_ = [("target", c.c_char_p), ("flags", c.c_uint), ("info", c.c_uint)]


get_type = c.CFUNCTYPE(None, ptr, ptr, c.c_uint, ptr)
clear_type = c.CFUNCTYPE(None, ptr, ptr)
signal_type = c.CFUNCTYPE(None, ptr, ptr)
init = bind(gtk, "gtk_init", None, ptr, ptr)
window_new = bind(gtk, "gtk_window_new", ptr, c.c_int)
title = bind(gtk, "gtk_window_set_title", None, ptr, c.c_char_p)
entry_new = bind(gtk, "gtk_entry_new", ptr)
add = bind(gtk, "gtk_container_add", None, ptr, ptr)
show = bind(gtk, "gtk_widget_show_all", None, ptr)
focus = bind(gtk, "gtk_widget_grab_focus", None, ptr)
atom = bind(gdk, "gdk_atom_intern_static_string", ptr, c.c_char_p)
clipboard_get = bind(gtk, "gtk_clipboard_get", ptr, ptr)
set_offer = bind(gtk, "gtk_clipboard_set_with_data", c.c_int,
                 ptr, c.POINTER(Target), c.c_uint, get_type, clear_type, ptr)
set_text = bind(gtk, "gtk_selection_data_set_text", c.c_int, ptr, c.c_char_p, c.c_int)
connect = bind(gobject, "g_signal_connect_data", c.c_ulong,
               ptr, c.c_char_p, signal_type, ptr, ptr, c.c_int)
main = bind(gtk, "gtk_main", None)
quit_main = bind(gtk, "gtk_main_quit", None)

log = Path(sys.argv[1])
mode = sys.argv[2]
names = [b"text/plain;charset=utf-8", b"UTF8_STRING"]
if mode == "sensitive":
    names.append(b"application/x-nspasteboard-concealed-type")
targets = (Target * len(names))(*(Target(name, 0, i) for i, name in enumerate(names)))


@get_type
def requested(_clipboard, selection, info, _data):
    with log.open("a") as stream:
        stream.write("requested:" + names[info].decode() + "\n")
    text = b"" if mode == "empty" else b"x" * 65537 if mode == "oversized" else b"fixture clipboard text"
    set_text(selection, text, -1)


@clear_type
def cleared(_clipboard, _data):
    pass


@signal_type
def publish(_entry, _data):
    accepted = set_offer(clipboard, targets, len(targets), requested, cleared, None)
    with log.open("a") as stream:
        stream.write("published:" + str(accepted) + "\n")


@signal_type
def destroy(_window, _data):
    quit_main()


init(None, None)
clipboard = clipboard_get(atom(b"CLIPBOARD"))
window = window_new(0)
title(window, b"ghostty-offer-test")
entry = entry_new()
add(window, entry)
connect(entry, b"activate", publish, None, None, 0)
connect(window, b"destroy", destroy, None, None, 0)
show(window)
focus(entry)
main()
