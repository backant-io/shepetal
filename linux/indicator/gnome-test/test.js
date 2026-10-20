// Runs linux/gnome-extension/extension.js (imports rewritten to ./stubs.js by check.sh) against a
// real Unix socket in $XDG_RUNTIME_DIR: placement, click-through, states and text, disable while
// connected and while connecting, a quick disable(); enable(), the daemon going away and coming
// back. Any exception in a callback is a "JS ERROR" line on stderr, which check.sh fails on.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import System from 'system';
import ShepetalIndicator from './extension.js';
import {Main} from './stubs.js';

const path = GLib.build_filenamev([GLib.get_user_runtime_dir(), 'shepetal.sock']);
let failed = false;
const check = (ok, what) => {
    print(`${ok ? 'ok' : 'FAIL'} gnome: ${what}`);
    failed ||= !ok;
};
const spin = (ms, until = () => false) => {
    const end = GLib.get_monotonic_time() + ms * 1000;
    while (GLib.get_monotonic_time() < end && !until())
        GLib.MainContext.default().iteration(false) || GLib.usleep(5000);
};

// The daemon's side: sends the current state and a hint to each indicator that connects.
let daemon = null;
const conns = [];
const startDaemon = () => {
    daemon = new Gio.SocketService();
    daemon.add_address(new Gio.UnixSocketAddress({path}), Gio.SocketType.STREAM, Gio.SocketProtocol.DEFAULT, null);
    daemon.connect('incoming', (_s, conn) => {
        conns.push(conn);
        conn.get_output_stream().write_all('recording\nhint Hold fn to talk · double-tap for hands-free\n', null);
        return true;
    });
    daemon.start();
};
const stopDaemon = () => {
    daemon.stop();
    daemon.close();
    conns.splice(0).forEach(c => c.close(null));
    GLib.unlink(path);
};

startDaemon();
const ext = new ShepetalIndicator();
ext.enable();
spin(3000, () => ext._text?.visible);
const box = ext._box;
check(box.visible, '🤫 shows once the daemon answers');
check(box.x === 8 && box.y === 720 - 8 - 18, `bottom-left, 8 px in (at ${box.x},${box.y})`);
const chrome = Main.layoutManager.chrome.at(-1);
check(chrome.actor === box && chrome.opts.affectsInputRegion === false && box.reactive === false && box.can_focus === false,
    'top chrome outside the input region, not reactive, never focused: click-through');
check(ext._emoji.style.includes('#ff3b30'), 'red ring while recording');
check(ext._text.text === 'Hold fn to talk · double-tap for hands-free', 'the hint shows next to 🤫');
spin(2300, () => !ext._text.visible);
check(!ext._text.visible, 'the hint is gone after about 2 s');

ext.disable(); // while connected: the pending read is cancelled
spin(300);
check(box.destroyed && ext._box === null, 'disable while connected cleans up');

ext.enable();
ext.disable(); // while connecting
spin(300);
check(true, 'disable while connecting');

ext.enable();
ext.disable();
ext.enable(); // GNOME does this when another extension is turned off
spin(3000, () => ext._text?.visible);
spin(300);
check(ext._box.visible && ext._conn !== null && !ext._conn.is_closed(), 'a quick disable(); enable() keeps the new connection');

stopDaemon();
spin(1000, () => !ext._box.visible);
check(!ext._box.visible, '🤫 hides when the daemon stops');
startDaemon();
spin(4000, () => ext._box.visible);
check(ext._box.visible, '🤫 is back within about 2 s of the daemon starting again');

ext.disable();
spin(300);
stopDaemon();
System.exit(failed ? 1 : 0);
