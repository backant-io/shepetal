# Brand on the site

The source of truth is `brand/` at the repo root (version 2.1, on branch `feat/brand` until it is merged): `identity.md` for the look, `voice.md` for the words, `tokens.css` and `tokens.json` for the values, and the generated logo, icon and image files. This folder holds only copies of what the site uses. Change a value or a file in `brand/` first, then copy it here again. Never edit the copies.

## What is copied, and where

| Here | From `brand/` | Used by |
|---|---|---|
| `src/brand/tokens.css` | `tokens.css`, unchanged | Imported by `src/app/(site)/layout.tsx`: the `--sh-` colors, fonts, scale, space, radius and motion, dark mode and reduced motion. |
| `src/brand/fonts/*.woff2` | `fonts/*.woff2` | The `@font-face` rules in `tokens.css`. Next bundles them into `/_next/static/media`, so no font loads from another server. |
| `src/brand/fonts/licenses/` | `fonts/licenses/` | Newsreader and Hanken Grotesk, both SIL Open Font License 1.1. Keep the licenses next to the fonts. |
| `public/brand/shepetal-wordmark-*.svg` | `logo/` | The logo, on-light and on-dark. The `small` master is for 80 to 160 px wide (the header); the full wordmark is for 160 px and up. |
| `public/favicon.ico`, `favicon.svg`, `apple-touch-icon.png`, `icon-192.png`, `icon-512.png`, `icon-maskable-512.png`, `site.webmanifest` | `assets/favicon/` | The tab and web app icons: the Noto 🤫. |
| `public/brand/emoji/` | `icon/emoji/` | The unmodified Noto 🤫 (`emoji_u1f92b.svg`) for drawing the indicator, with its Apache 2.0 license and attribution notice, which must ship with the site. |
| `public/og.jpg` | `assets/og/og-dark.png`, saved as JPEG | The link preview, 1200 × 630 on the afterglow: "Instant dictation that stays on your Mac." A static file at an absolute URL (`openGraph.images` in the site layout), so X and other cards fetch it without waking the Worker. |
| `public/brand/imagery/` | `assets/imagery/` | Version 1 images, AVIF and WebP, 2,400 px wide: `mist-lake`, `night-air`, `dusk-room`, `river-fog`. |
| `public/brand/imagery/{last-light,dusk-air,train,valley}-*` | made for the landing page | Version 2 photographs from the imagery prompts in `identity.md` (Last light, Dusk air, and two in the same style), AVIF and WebP in the widths in their names: the hero screen by day and by night, the offline scene and the name story. |
| `src/app/(site)/fonts/` | `fonts/desktop/*.ttf`, cut by `fonts/subset.py` | The website's own cut of the brand fonts (Latin, Latin-1, š, typographic punctuation, the weights in use), renamed "shepetal Serif" and "shepetal Sans" as the OFL asks for modified fonts. 120 KB in place of 270 KB. `fonts.css` puts them first in `--sh-font-display` and `--sh-font-text`; the full fonts stay as the fallback. |
| `public/brand/grain.svg` | `texture/grain.svg` | The grain for large brand surfaces such as the hero. Tile it at 256 px, `--sh-grain-opacity`. |

To refresh the copies, from the repo root:

```
cp brand/tokens.css web/src/brand/
cp brand/fonts/*.woff2 web/src/brand/fonts/ && cp brand/fonts/licenses/* web/src/brand/fonts/licenses/
cp brand/logo/shepetal-wordmark-*.svg web/public/brand/
cp brand/assets/favicon/{favicon.ico,favicon.svg,apple-touch-icon.png,icon-192.png,icon-512.png,icon-maskable-512.png,site.webmanifest} web/public/
cp brand/icon/emoji/* web/public/brand/emoji/
```

and for the link preview:

```
sips -s format jpeg -s formatOptions 85 brand/assets/og/og-dark.png --out web/public/og.jpg
```

and the same for any image listed above.

## Wiring

- `src/app/(site)/site.css` keeps its short names (`--paper`, `--ink`, `--hush`, `--line`, `--rec`, `--busy`...) as aliases of the `--sh-` tokens. New code can use the `--sh-` tokens directly.
- Dark mode follows the system (`prefers-color-scheme`). `tokens.css` also honors `data-theme="light"` and `data-theme="dark"` on `<html>`. The browser theme color is blush by day and dusk by night (`viewport.themeColor` in the site layout).
- Logos are plain `<img>` in a `<picture>` that swaps in the on-dark file in dark mode. The site has no image optimization binding, so images are served as they are.
- The icons are set in `metadata.icons` and `metadata.manifest` in `src/app/(site)/layout.tsx`. `/favicon.ico` also covers pages outside that layout, because browsers ask for it at the root.
- The brand images are version 1 artwork and cooler than the palette. Until they are remade, tint them into it as `brand/assets/kit.css` does: an overlay of `--sh-neutral-200` (day) or `--sh-neutral-800` (night) with `mix-blend-mode: color` at 0.9 opacity.

## Rules the site must keep

From `identity.md` and `voice.md`:

- The name is **shepetal**, always lowercase, also at the start of a sentence. The logo is the wordmark alone: use the files, never retype it in a font, and never put 🤫 or any other symbol next to it. The š appears only in the one line that explains the name.
- 🤫 is the favicon, the app icon and the indicator, nothing else: never in headings or as decoration. Draw it from `public/brand/emoji/emoji_u1f92b.svg`, never as a typed 🤫, which shows Apple's artwork on a Mac.
- The indicator is drawn as the app draws it: the 🤫 in an 18 px circle, 8 px in from the bottom-left corner, with a 2 px ring inside the circle and no glow. Red is recording, orange hands-free, blue writing (the whole indicator pulses to 35 % opacity, 600 ms each way). Always name the state in words too.
- Color means state. Red, orange, blue and yellow (`--sh-recording`, `--sh-hands-free`, `--sh-writing`, `--sh-note`) belong to the indicator, never to buttons or decoration. The brand is blush, dusk and one accent, Mulberry (`--sh-accent`).
- One Mulberry field per surface at most: the afterglow (`--sh-gradient-afterglow`) or one Mulberry 600 or 700 panel, with blush text only. Mulberry 500 never goes into the UI. No violet, lavender or multi-color gradients.
- Newsreader for headlines and reading text, Hanken Grotesk for everything else, the system monospace for code. Newsreader roman only. No bold or italic for stress in headlines. Sentence case everywhere.
- Motion uses the `--sh-dur-*` and `--sh-ease-*` tokens, which drop to 0 ms under reduced motion. Nothing bounces or overshoots.
- Illustrations of where text lands (an editor, a terminal, a mail window) are labeled "Illustration" and name no real tool.
- The approved lines ("Effortless voice-to-text that transforms the way you work.", "100% private. Your data is yours." and "Instant, real-time, 4x faster.") are used as written and always with their proof (`voice.md`, Approved lines): a footnote, a link to it, or the proof sentence close by.
- Copy says what happens, never the steps: "Press one key. Your words appear wherever you speak." "Hold fn, speak, let go." and its variants are not brand copy. The app's own hint ("Hold fn to talk · double-tap for hands-free") may be shown as the app shows it.
- Link previews (the description, the OG image and its alt text) carry no price.
- Never name a speech recognition or AI model. No made-up testimonials, user counts, ratings or logos.
- Where Apple products are named, the footer carries: "Mac and macOS are trademarks of Apple Inc., registered in the U.S. and other countries and regions." Write "Apple silicon" with a lowercase s.
