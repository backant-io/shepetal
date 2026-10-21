# Brand on the site

The source of truth is `brand/` at the repo root (branch `feat/brand` until it is merged): `identity.md` for the look, `voice.md` for the words, `tokens.css` and `tokens.json` for the values, and the generated logo, favicon and image files. This folder holds only copies of what the site uses. Change a value or a file in `brand/` first, then copy it here again. Never edit the copies.

## What is copied, and where

| Here | From `brand/` | Used by |
|---|---|---|
| `src/brand/tokens.css` | `tokens.css`, unchanged | Imported by `src/app/(site)/layout.tsx`. The `--sh-` colors, fonts, scale, space, radius and motion, the dark mode and reduced motion. |
| `src/brand/fonts/*.woff2` | `fonts/*.woff2` | The `@font-face` rules in `tokens.css`. Next bundles them into `/_next/static/media`, so no font is loaded from another server. |
| `src/brand/fonts/licenses/` | `fonts/licenses/` | Newsreader and Hanken Grotesk, both SIL Open Font License 1.1. Keep the licenses next to the fonts. |
| `public/brand/shepetal-wordmark-*.svg` | `logo/` | The header uses the small-size master (80 to 160 px wide). The full wordmark is for 160 px and up. |
| `public/brand/shepetal-mark-*.svg` | `logo/` | The š mark. |
| `public/favicon.svg`, `favicon-32.png`, `favicon-16.png`, `apple-touch-icon.png` | `favicon/` | The tab icon (the š mark, the default). |
| `public/favicon-emoji.svg` | `favicon/` | The 🤫 tab icon, the documented alternative. |
| `src/app/(site)/opengraph-image.png` | `assets/og/og-default.png` | The link preview. Its alt text is in `opengraph-image.alt.txt`. |
| `public/brand/imagery/` | `assets/imagery/` | Mist and night backgrounds (`mist-lake`, `night-air`, `river-fog`), AVIF and WebP, 2,400 px wide. |
| `public/brand/grain.svg` | `texture/grain.svg` | The grain for large brand surfaces such as the hero. Tile it at 256 px, `--sh-grain-opacity`. |

To refresh the copies, from the repo root:

```
cp brand/tokens.css web/src/brand/
cp brand/fonts/*.woff2 web/src/brand/fonts/ && cp brand/fonts/licenses/* web/src/brand/fonts/licenses/
```

and the same for any logo, favicon or image listed above.

## Wiring

- `src/app/(site)/site.css` keeps its short names (`--paper`, `--ink`, `--hush`, `--line`, `--rec`, `--busy`...) as aliases of the `--sh-` tokens. New code can use the `--sh-` tokens directly.
- Dark mode follows the system (`prefers-color-scheme`). `tokens.css` also honors `data-theme="light"` and `data-theme="dark"` on `<html>`.
- Logos are plain `<img>` in a `<picture>` that swaps the on-dark file in dark mode. The site has no image optimization binding, so images are served as they are.
- The tab icon is set by `FAVICON` in `src/app/(site)/layout.tsx`. `'mark'` (the default) uses the š set; `'emoji'` uses `favicon-emoji.svg` alone. Never both on one site. The emoji file draws 🤫 as a text character, so every viewer sees their own system's emoji and no emoji artwork is shipped.

## Rules the site must keep

From `identity.md` and `voice.md`:

- The name is **shepetal**, always lowercase, also at the start of a sentence. In the header, use the wordmark files; never retype it in a font.
- Never put 🤫 or any symbol next to the wordmark. 🤫 appears only as the indicator and, when chosen, the tab icon.
- Color means state. Red, orange, blue and yellow belong to the indicator (`--sh-recording`, `--sh-hands-free`, `--sh-writing`, `--sh-note`), never to buttons or decoration. The brand is mist, night and the Soča accent.
- Newsreader for headlines and reading text, Hanken Grotesk for everything else. No bold or italic for stress in headlines.
- Motion uses the `--sh-dur-*` and `--sh-ease-*` tokens, which drop to 0 ms under reduced motion.
- Never name a speech recognition or AI model. No made-up testimonials, user counts or logos.
