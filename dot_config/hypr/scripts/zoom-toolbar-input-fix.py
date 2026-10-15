#!/usr/bin/python3
"""Repair Zoom's mislabelled XWayland sharing toolbar, without changing focus."""
import ctypes as C
import ctypes.util
import json
import os
from pathlib import Path
import signal
import time

U = C.c_ulong
P = C.c_void_p


def remove_tooltip(values, tooltip):
    # Preserve every other atom, including KDE's override and NORMAL.
    return [value for value in values if value != tooltip]


class X11:
    def __init__(self):
        self.x = C.CDLL(ctypes.util.find_library('X11'))
        self.x.XOpenDisplay.restype = P
        self.d = self.x.XOpenDisplay(None)
        if not self.d:
            raise RuntimeError('Cannot open session X display')
        specs = {
            'XDefaultRootWindow': ([P], U),
            'XInternAtom': ([P, C.c_char_p, C.c_int], U),
            'XQueryTree': ([P, U, C.POINTER(U), C.POINTER(U), C.POINTER(C.POINTER(U)), C.POINTER(C.c_uint)], C.c_int),
            'XGetWindowProperty': ([P, U, U, C.c_long, C.c_long, C.c_int, U, C.POINTER(U), C.POINTER(C.c_int), C.POINTER(U), C.POINTER(U), C.POINTER(P)], C.c_int),
            'XChangeProperty': ([P, U, U, U, C.c_int, C.c_int, P, C.c_int], C.c_int),
            'XFree': ([P], C.c_int),
            'XSync': ([P, C.c_int], C.c_int),
            'XCloseDisplay': ([P], C.c_int),
        }
        for name, (args, result) in specs.items():
            fn = getattr(self.x, name)
            fn.argtypes, fn.restype = args, result
        # Windows may disappear between discovery and property reads. Do not let
        # the default Xlib error handler terminate the watcher on that race.
        self.errors = []
        self.handler = C.CFUNCTYPE(C.c_int, P, P)(self.on_error)
        self.x.XSetErrorHandler.argtypes = [type(self.handler)]
        self.x.XSetErrorHandler(self.handler)
        self.atoms = {}

    def on_error(self, display, event):
        self.errors.append(True)
        return 0

    def atom(self, name):
        if name not in self.atoms:
            self.atoms[name] = self.x.XInternAtom(self.d, name.encode(), 0)
        return self.atoms[name]

    def prop(self, window, name):
        actual, fmt, count, remaining, data = U(), C.c_int(), U(), U(), P()
        status = self.x.XGetWindowProperty(self.d, window, self.atom(name), 0, 1024, 0, 0,
            C.byref(actual), C.byref(fmt), C.byref(count), C.byref(remaining), C.byref(data))
        try:
            if status or not data:
                return None
            if fmt.value == 8:
                return C.string_at(data, count.value)
            if fmt.value == 32:
                ptr = C.cast(data, C.POINTER(U))
                return [ptr[i] for i in range(count.value)]
            return None
        finally:
            if data:
                self.x.XFree(data)

    def windows(self):
        # XWayland's application windows are root children; include descendants
        # for compatibility with reparenting, while bounding unexpected trees.
        pending = [(self.x.XDefaultRootWindow(self.d), 0)]
        while pending:
            window, depth = pending.pop()
            if depth:
                yield window
            if depth >= 5:
                continue
            root, parent, children, count = U(), U(), C.POINTER(U)(), C.c_uint()
            if self.x.XQueryTree(self.d, window, C.byref(root), C.byref(parent), C.byref(children), C.byref(count)):
                try:
                    pending.extend((children[i], depth + 1) for i in range(count.value))
                finally:
                    if children:
                        self.x.XFree(children)

    def repair(self):
        repaired = []
        self.errors.clear()
        for window in self.windows():
            if self.prop(window, 'WM_NAME') != b'as_toolbar':
                continue
            wm_class = self.prop(window, 'WM_CLASS') or b''
            if b'zoom' not in wm_class.lower().split(b'\0'):
                continue
            pids = self.prop(window, '_NET_WM_PID')
            if not pids or len(pids) != 1:
                continue
            try:
                executable = Path(f'/proc/{pids[0]}/exe').resolve(strict=True).name
            except OSError:
                continue
            if executable != 'zoom':
                continue
            old = self.prop(window, '_NET_WM_WINDOW_TYPE')
            tooltip = self.atom('_NET_WM_WINDOW_TYPE_TOOLTIP')
            if not isinstance(old, list) or tooltip not in old:
                continue
            new = remove_tooltip(old, tooltip)
            if not new:
                # Never invent a replacement type for an unexpected toolbar.
                continue
            # Keep the first original type list for each exact window/PID pair.
            runtime = Path(os.environ['XDG_RUNTIME_DIR']) / 'zoom-toolbar-input-fix'
            runtime.mkdir(mode=0o700, exist_ok=True)
            backup = runtime / f'{window:x}-{pids[0]}.json'
            if not backup.exists():
                backup.write_text(json.dumps({'window': window, 'pid': pids[0], 'original': old}))
                backup.chmod(0o600)
            values = (U * len(new))(*new)
            self.x.XChangeProperty(self.d, window, self.atom('_NET_WM_WINDOW_TYPE'),
                self.atom('ATOM'), 32, 0, C.cast(values, P), len(new))
            self.x.XSync(self.d, 0)
            if self.prop(window, '_NET_WM_WINDOW_TYPE') == new:
                repaired.append(window)
                print(f'Repaired Zoom as_toolbar {window:#x}, PID {pids[0]}', flush=True)
        return repaired


def main():
    running = True
    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    connection = X11()
    try:
        while running:
            connection.repair()
            time.sleep(1)
    finally:
        connection.x.XCloseDisplay(connection.d)


if __name__ == '__main__':
    main()
