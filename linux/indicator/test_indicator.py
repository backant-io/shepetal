"""Tests for shepetal-indicator.

  python3 linux/indicator/test_indicator.py                 unit tests, no display needed
  python3 linux/indicator/test_indicator.py shot PNG STATE [TEXT]
      checks a real screenshot: 🤫 in the bottom-left corner with the ring for STATE, the text
      box next to it only with TEXT, and nothing else on screen. linux/indicator/check.sh runs it.
  python3 linux/indicator/test_indicator.py pulse PNG PNG PNG
      checks shots taken about 0.3 s apart while processing: a blue ring that pulses.
"""
import importlib.machinery
import importlib.util
import os
import sys
import unittest

sys.dont_write_bytecode = True  # no __pycache__ next to the script
_here = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("indicator", os.path.join(_here, "shepetal-indicator"))
ind = importlib.util.module_from_spec(importlib.util.spec_from_loader("indicator", _loader))
_loader.exec_module(ind)


class Placement(unittest.TestCase):
    # Goal rule 3: about 18 px, about 8 px in from the bottom-left corner of the main display.
    def test_bottom_left_of_a_1080p_monitor(self):
        self.assertEqual(ind.origin((0, 0, 1920, 1080)), (8, 1080 - 8 - 18))

    def test_primary_monitor_right_of_or_below_another(self):
        # GDK puts every monitor in one coordinate space; the corner is the primary's own.
        self.assertEqual(ind.origin((2560, 0, 1920, 1080)), (2568, 1054))
        self.assertEqual(ind.origin((0, 1440, 1280, 720)), (8, 1440 + 720 - 26))

    def test_stays_tiny_and_the_text_extends_to_the_right(self):
        self.assertEqual((ind.SIZE, ind.INSET), (18, 8))
        self.assertEqual(ind.width(None), 18, "no text: only 🤫")
        self.assertEqual(ind.width(100), 18 + 6 + 4 + 100 + 4)


class States(unittest.TestCase):
    # README "Mac": red recording, orange hands-free, pulsing blue processing, yellow error.
    def test_ring_per_state(self):
        r, o, b, y = (ind.RING[s] for s in ("recording", "handsfree", "processing", "error"))
        self.assertIsNone(ind.RING["idle"], "idle shows 🤫 alone")
        self.assertTrue(r[0] > 0.9 and r[1] < 0.3 and r[2] < 0.3, f"recording is red: {r}")
        self.assertTrue(o[0] > 0.9 and 0.4 < o[1] < 0.7 and o[2] < 0.1, f"hands-free is orange: {o}")
        self.assertTrue(b[2] > 0.9 and b[0] < 0.1, f"processing is blue: {b}")
        self.assertTrue(y[0] > 0.9 and y[1] > 0.7 and y[2] < 0.1, f"error is yellow: {y}")

    def test_daemon_lines(self):
        # The lines linux/src/indicator.rs sends.
        self.assertEqual(ind.parse("recording\n"), ("recording", None, 0))
        self.assertEqual(ind.parse("handsfree"), ("handsfree", None, 0))
        self.assertEqual(ind.parse("processing"), ("processing", None, 0))
        self.assertEqual(ind.parse("idle"), ("idle", None, 0))

    def test_hint_shows_for_about_3_s_and_keeps_the_ring(self):
        # Goal rule 2: the short-press hint sits next to 🤫 for about 3 s.
        hint = "Hold fn to talk · double-tap for hands-free"
        self.assertEqual(ind.parse(f"hint {hint}\n"), (None, hint, 3))

    def test_error_is_yellow_with_its_text_for_4_s(self):
        self.assertEqual(ind.parse("error Transcription failed"), ("error", "Transcription failed", 4))
        # A late indicator gets the bare state: yellow, no stale text.
        self.assertEqual(ind.parse("error\n"), ("error", None, 4))

    def test_unknown_or_empty_lines_change_nothing(self):
        for line in ("", "\n", "hint", "hint ", "pasted ok", "RECORDING"):
            self.assertEqual(ind.parse(line), (None, None, 0), repr(line))

    def test_processing_pulses_like_the_mac(self):
        # 1 → 0.35 in 0.6 s, back in 0.6 s, linear, forever.
        for t, a in ((0, 1), (0.3, 0.675), (0.6, 0.35), (0.9, 0.675), (1.2, 1), (6.6, 0.35)):
            self.assertAlmostEqual(ind.pulse_alpha(t), a, places=6, msg=f"t={t}")


def check_shot(png, state, text=None):
    """Assert on a screenshot of the whole screen."""
    import gi
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf

    pb = GdkPixbuf.Pixbuf.new_from_file(png)
    w, h, n, stride, px = pb.get_width(), pb.get_height(), pb.get_n_channels(), pb.get_rowstride(), pb.get_pixels()

    def at(x, y):
        i = y * stride + x * n
        return tuple(px[i:i + 3])

    bg = at(w - 1, 0)
    x0, y0 = ind.INSET, h - ind.INSET - ind.SIZE
    box = (x0, y0, x0 + ind.SIZE, y0 + ind.SIZE)  # 🤫 and its ring
    text_box = (box[2], y0, box[2] + 400, box[3])

    def inside(x, y, b):
        return b[0] <= x < b[2] and b[1] <= y < b[3]

    stray = [(x, y) for y in range(0, h, 2) for x in range(0, w, 2)
             if at(x, y) != bg and not inside(x, y, box) and not (text and inside(x, y, text_box))]
    assert not stray, f"{png}: drawn outside the corner, e.g. {stray[:5]}"
    drawn = [at(x, y) for y in range(box[1], box[3]) for x in range(box[0], box[2]) if at(x, y) != bg]
    assert len(drawn) > ind.SIZE * ind.SIZE // 4, f"{png}: no 🤫 at {box[:2]}: {len(drawn)} pixels"
    # The ring's left edge, middle row: outside the 13 px glyph, inside the 2 px stroke.
    edge = at(x0, y0 + ind.SIZE // 2)
    ring = ind.RING[state]
    if state == "processing":
        # Faded by the pulse, over the screen or (plain X11) over black: blue still leads.
        assert edge[2] - max(edge[:2]) >= 30, f"{png}: ring {edge} is not blue"
    else:
        # The face is yellow: many pixels with red and green high and blue low.
        face = [p for p in drawn if p[0] > 200 and p[1] > 150 and p[2] < 120]
        assert len(face) > 20, f"{png}: 🤫 has no yellow face: {len(face)} pixels"
    if ring is None:
        assert edge == bg, f"{png}: idle has no ring, got {edge} at the ring's edge"
    elif state != "processing":
        want = tuple(round(c * 255) for c in ring)
        assert all(abs(a - b) < 60 for a, b in zip(edge, want)), f"{png}: ring {edge}, want about {want} for {state}"
    shown = [at(x, y) for y in range(text_box[1], text_box[3]) for x in range(text_box[0], text_box[2])]
    # Subpixel antialiasing tints the strokes, so "white" is every channel above 160.
    white = sum(1 for p in shown if min(p) > 160 and p != bg)
    dark = sum(1 for p in shown if max(p) < 100 and p != bg)
    if text:
        assert white > 20 and dark > 100, f"{png}: no white text on a dark box ({white} white, {dark} dark)"
    else:
        assert not any(p != bg for p in shown), f"{png}: text box drawn without text"
    print(f"ok {png}: 🤫 at {box[:2]} on {w}x{h}, ring {edge} for {state}, text {'shown' if text else 'none'}")
    return edge


def check_pulse(pngs):
    blues = [check_shot(p, "processing")[2] for p in pngs]
    assert max(blues) - min(blues) >= 40, f"processing ring does not pulse: blue {blues}"
    print(f"ok processing pulses: ring blue {blues}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["shot"]:
        check_shot(sys.argv[2], sys.argv[3], " ".join(sys.argv[4:]) or None)
    elif sys.argv[1:2] == ["pulse"]:
        check_pulse(sys.argv[2:])
    else:
        unittest.main()
