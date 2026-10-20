// Stand-ins for the GNOME Shell modules extension.js uses (St, Clutter, Main, Extension), so its
// lifecycle runs under plain gjs. Gio and GLib stay real. An actor used after destroy() throws,
// the way a stale callback would hit a disposed actor in GNOME Shell.
class Actor {
    constructor(props = {}) {
        this.visible = true;
        this.opacity = 255;
        this.children = [];
        this.destroyed = false;
        Object.assign(this, props);
    }

    _alive() {
        if (this.destroyed)
            throw new Error('actor used after destroy()');
    }

    add_child(c) {
        this._alive();
        this.children.push(c);
    }

    show() {
        this._alive();
        this.visible = true;
    }

    hide() {
        this._alive();
        this.visible = false;
    }

    set_position(x, y) {
        this._alive();
        this.x = x;
        this.y = y;
    }

    remove_all_transitions() {
        this._alive();
    }

    ease(p) {
        this._alive();
        this.eased = p;
    }

    destroy() {
        this.destroyed = true;
    }
}

export const St = {
    BoxLayout: Actor,
    Label: Actor,
    Bin: Actor,
    ThemeContext: {get_for_stage: () => ({scale_factor: 1})},
};

export const Clutter = {ActorAlign: {CENTER: 0}, AnimationMode: {LINEAR: 0}};

export const Main = {
    layoutManager: {
        primaryMonitor: {x: 0, y: 0, width: 1280, height: 720},
        chrome: [],
        addTopChrome(actor, opts) {
            this.chrome.push({actor, opts});
        },
        connect() {
            return 1;
        },
        disconnect() {},
    },
};

export class Extension {}

globalThis.global = {stage: {}};
