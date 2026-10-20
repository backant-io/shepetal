// The shepetal 🤫 indicator for GNOME Shell (45 and later), where no app can place an overlay.
// It draws 🤫 about 18 px, 8 px in from the bottom-left corner of the primary monitor, above
// windows (full-screen ones too), click-through, and reads the daemon's state lines from
// $XDG_RUNTIME_DIR/shepetal.sock (linux/src/indicator.rs). Hidden while the daemon is not running.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const SIZE = 18;
const INSET = 8;
const RETRY_S = 2;
// Apple's system red, orange, blue and yellow, as on the Mac and in linux/indicator/.
const RING = {
    recording: '#ff3b30',
    handsfree: '#ff9500',
    processing: '#007aff',
    error: '#ffcc00',
};
const TEXT_MS = {hint: 2000, error: 4000};
const EMOJI_STYLE = `width: ${SIZE}px; height: ${SIZE}px; border-radius: ${SIZE / 2}px; font-size: 13px;`;
const TEXT_STYLE = 'font-size: 11px; font-weight: 500; color: white; background-color: rgba(0,0,0,0.75); border-radius: 4px; padding: 0 4px;';

export default class ShepetalIndicator extends Extension {
    enable() {
        this._cancel = new Gio.Cancellable();
        this._box = new St.BoxLayout({reactive: false, can_focus: false, track_hover: false, visible: false, style: 'spacing: 6px;'});
        // The ring is the circle's border; the glyph is centered inside it.
        const glyph = new St.Label({text: '🤫', x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER});
        this._emoji = new St.Bin({style: EMOJI_STYLE, child: glyph});
        this._text = new St.Label({style: TEXT_STYLE, visible: false, y_align: Clutter.ActorAlign.CENTER});
        this._box.add_child(this._emoji);
        this._box.add_child(this._text);
        // Top chrome sits above all windows; not part of the input region, so clicks go through.
        Main.layoutManager.addTopChrome(this._box, {affectsInputRegion: false, trackFullscreen: false});
        this._monitors = Main.layoutManager.connect('monitors-changed', () => this._place());
        this._place();
        this._connect();
    }

    disable() {
        this._cancel.cancel();
        for (const id of [this._retry, this._textTimer])
            if (id)
                GLib.source_remove(id);
        this._retry = this._textTimer = 0;
        this._conn?.close(null);
        this._conn = this._lines = null;
        Main.layoutManager.disconnect(this._monitors);
        this._box.destroy();
        this._box = this._emoji = this._text = this._cancel = null;
    }

    _place() {
        const m = Main.layoutManager.primaryMonitor;
        if (!m)
            return;
        const s = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        this._box.set_position(m.x + INSET * s, m.y + m.height - (INSET + SIZE) * s);
    }

    _connect() {
        const path = GLib.build_filenamev([GLib.get_user_runtime_dir(), 'shepetal.sock']);
        new Gio.SocketClient().connect_async(new Gio.UnixSocketAddress({path}), this._cancel, (client, res) => {
            try {
                this._conn = client.connect_finish(res);
            } catch {
                if (!this._cancel.is_cancelled())
                    this._retryLater();
                return;
            }
            this._lines = new Gio.DataInputStream({base_stream: this._conn.get_input_stream()});
            this._box.show();
            this._read();
        });
    }

    _retryLater() {
        this._retry = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, RETRY_S, () => {
            this._retry = 0;
            this._connect();
            return GLib.SOURCE_REMOVE;
        });
    }

    _read() {
        this._lines.read_line_async(GLib.PRIORITY_DEFAULT, this._cancel, (stream, res) => {
            let line = null;
            try {
                [line] = stream.read_line_finish_utf8(res);
            } catch {
                // A read error or invalid UTF-8: handled as a closed connection below.
            }
            if (this._cancel.is_cancelled())
                return;
            if (line === null) {
                // The daemon stopped: hide 🤫 and wait for the next one.
                this._conn.close(null);
                this._conn = this._lines = null;
                this._box.hide();
                this._retryLater();
                return;
            }
            this._apply(line);
            this._read();
        });
    }

    // One daemon line: `idle`, `recording`, `handsfree`, `processing`, `error <text>` or
    // `hint <text>`. Unknown lines are ignored.
    _apply(line) {
        const i = line.indexOf(' ');
        const word = i < 0 ? line : line.slice(0, i);
        const text = i < 0 ? '' : line.slice(i + 1);
        if (word === 'idle' || Object.hasOwn(RING, word))
            this._ring(word);
        if (Object.hasOwn(TEXT_MS, word) && text)
            this._show(text, TEXT_MS[word]);
    }

    _ring(state) {
        const color = RING[state]; // undefined for idle: no ring
        this._emoji.style = color ? `${EMOJI_STYLE} border: 2px solid ${color};` : EMOJI_STYLE;
        this._emoji.remove_all_transitions();
        this._emoji.opacity = 255;
        if (state === 'processing') {
            this._emoji.ease({
                opacity: Math.round(255 * 0.35),
                duration: 600,
                mode: Clutter.AnimationMode.LINEAR,
                autoReverse: true,
                repeatCount: -1,
            });
        }
    }

    _show(text, ms) {
        if (this._textTimer)
            GLib.source_remove(this._textTimer);
        this._text.text = text;
        this._text.show();
        this._textTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            this._textTimer = 0;
            this._text.hide();
            return GLib.SOURCE_REMOVE;
        });
    }
}
