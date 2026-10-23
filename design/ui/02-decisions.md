# Decisions

This system takes its look from the landing page and its rules from shepetal Brand 3.0. Each item below is a place where they disagree, or where three platforms raise a question the brand book has not had to answer. The first group is settled here; the second needs a decision from Pavel before the apps ship.

## Settled in this system

1. **Palette.** Concrete (`sh-stone-100`), ink (`sh-stone-900`) and signal (`sh-signal-500`) replace blush, dusk and Mulberry on every screen and page. Night is new: the landing page has no dark theme, so it is built from the landing page's own ink and concrete.
2. **Type.** Archivo, Fragment Mono and Bodoni Moda italic replace Newsreader and Hanken Grotesk. This also settles the brand book's question about a monospace for developer surfaces (Typography, open decision 13): it is back, as Fragment Mono.
3. **Radii.** 2, 4 and 8 px replace 6, 12 and 20 px.
4. **Signal is a state color.** The brand book keeps orange for the hands-free ring only. Here signal orange is the color of "live", and it stays a state color: it appears only while the key is down, a recording runs or text is landing. Nothing static is ever orange.
5. **Indicator states** stop relying on four hues. Recording is a full signal ring, hands-free a signal ring with a gap, writing an ink ring that pulses, a note a label. This follows the brand book's own advice to let states differ by shape or motion (Visual identity, open decision 4).
6. **Focus ring.** The landing page draws focus in `#FF4F12`, which is 2.6:1 on concrete. This system uses `sh-focus` (`sh-signal-800` by day, `sh-signal-400` by night), 5:1 or better everywhere.
7. **No overshoot.** The landing page's CTA eases with `cubic-bezier(.3,0,.2,1.4)` and the hero key rebounds on release. This system keeps the brand rule that nothing bounces: keys press on `sh-ease-press` and return on `sh-ease-settle`.
8. **Icons.** Lucide on every platform, including the Mac, because one UI ships everywhere and SF Symbols may only be used on Apple platforms.
9. **Text on the primary keycap in Night** is ink on concrete, the inverse of Concrete, so the primary keycap stays the strongest thing on screen in both themes.

## Needs a decision

1. **The wordmark.** The landing page sets shepetal in Bodoni Moda italic 500; the brand book's logo files are Newsreader. Until a drawn Bodoni wordmark exists, set it live with the `wordmark` style and never retype it in another face. Commission the drawn file before the figurative trademark filing.
2. **The app icon.** The brand book's icon is the Noto 🤫 on a Mulberry ground, which this palette no longer has. Proposal: the 🤫 on an ink ground (`sh-stone-900`) lit from above, with a 2 px signal ring that appears only in the tray or menu bar while recording. Windows needs `.ico` (16 to 256 px) and Linux a 512 px PNG plus a symbolic tray icon.
3. **The trigger key on Windows and Linux.** Most Windows and Linux keyboards do not send `fn` to the OS. Choose a default (Right Ctrl, Right Alt or a two-key shortcut) and let onboarding change it. The keycap, the hints and the copy then name that key.
4. **The afterglow.** The brand book's one Mulberry field (covers, title slides, film end cards) has no place in this palette. Proposal: the equivalent for those surfaces is a full night ground with the lit fn key as the one bold thing.
5. **Brand images.** The brand book's imagery was made for blush and dusk. Photographs of warm evening light on concrete or a desk fit this palette; remake the set before launch.
6. **Font files.** This system names its three families but does not carry the files yet. Download the variable woff2 files from Google Fonts (all three are SIL Open Font License), add them under `fonts/`, and ship them inside every app build with their license files.
7. **Platform copy.** "For Mac." is a claim today. When the Windows and Linux builds ship, "For Mac." becomes "For Mac, Windows and Linux." everywhere at once, and the downloads follow Platforms. Until then the site names no other platform.
