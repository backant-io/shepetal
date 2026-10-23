shepetal is dictation that stays on your computer. Press one key. Your words appear wherever you speak. This system is the interface layer for every shepetal surface: the website and the one shared app UI that ships as shepetal for Mac, shepetal for Linux and shepetal for Windows. It takes its look from the landing page (the key on a concrete desk) and its voice, naming and motion rules from shepetal Brand 3.0. Where the two disagree, this system wins for anything drawn on screen; see Decisions.

## The idea

A real key on a concrete desk. The ground is warm grey concrete by day and ink-black by night. Everything is ink until you press the key. Then one color appears, **signal orange**, and it means one thing: live. The key lights, the caret blinks, the ring around the 🤫 turns on. Let go and the color leaves. Words that have just been spoken are set in Bodoni italic; everything you operate is Archivo; everything you measure is Fragment Mono.

## Principles

1. **Signal means live.** `sh-signal` appears only while something is happening: the key is down, a recording runs, text is landing. One signal mark per view. Nothing static is ever orange.
2. **Keys travel.** Anything you press is a keycap with a side, and it goes down when pressed (`sh-key`, `sh-key-primary`, `sh-travel`). Nothing else on the screen has depth.
3. **Ink first.** Text, rules and the primary button are ink on concrete (`sh-text` on `sh-bg`). Hierarchy comes from size, weight and the mono labels, never from extra colors.
4. **The product is the picture.** Show real dictated text in real apps. No illustration, no waveforms, no microphones.
5. **Nothing interrupts.** The app makes no sounds. It sits in its corner and in the menu bar or tray, and the only thing that floats is the meeting reminder.

## Content

The voice is shepetal Brand 3.0's: clear, simple, concise, bold, direct. Read its Voice and Naming sections before you write a line. The rules that touch every screen:

- Write **shepetal**, lowercase, everywhere, at the start of a sentence too. With a platform: shepetal for Mac, shepetal for Linux, shepetal for Windows.
- Say what happens, from the reader's side: "Press one key. Your words appear wherever you speak." The brand line is "Write at the speed of thought."
- Use the claims exactly as written, once: "100% private. Your data is yours." "Works offline." "Instant." "4x faster than typing." "Works in every app." "Meetings, transcribed on your Mac." "30 days free." Prices ("$23.99 once. Yours forever." and "$0.99 a month.") appear on the site and X only.
- The brand says "we" and "you". Screens are **Home**, **History**, **Meetings**, **Settings**, **Dictionary**. The 🤫 in the corner is **the indicator**; its states are **recording**, **hands-free**, **writing** and **a note**. The prompt when a call starts is **the meeting reminder**.
- In the app, ask first and say why in one sentence: "Accessibility lets shepetal paste your text where your cursor is." Name the limit, then the way around it: "Password fields block pasting. Your text is on the clipboard: press ⌘V."
- No em dashes, no exclamation marks, no capitals for emphasis, no hedges (about, up to, may, typically), no "AI", no model names, no other product's name.
- Buttons say exactly what they do ("Record", "Not now", "Copy text"), and the toast after says it done ("Copied").
- Key names follow the platform: `fn` and `⌘V` on Mac; `Ctrl+V` with a plus on Linux and Windows. Platforms has the full table.

## Color

- Read colors only through the semantic tokens. `sh-bg` for the window and page, `sh-bg-raised` for cards, menus and the reminder, `sh-bg-sunken` for the sidebar, wells and the selected row, `sh-bg-field` for inputs.
- Text is `sh-text`; secondary text and every mono label is `sh-text-muted`. Both pass 4.5:1 on all four grounds in both themes.
- `sh-signal` is a fill or a mark: the fn key, the LED, the caret, the recording ring. On concrete it is 2.6:1, so it is never text by day. Text on a signal fill is `sh-on-signal` (ink, 5.5:1).
- When signal must be text (a link, a signal word), use `sh-accent`: `sh-signal-800` by day, `sh-signal-400` by night.
- The one primary button per view is `sh-primary-fill` with `sh-on-primary`: ink by day, concrete by night.
- Hairlines are `sh-border` (ink at 22 %, the landing page's rule). Edges of inputs, toggles and segmented controls are `sh-border-strong`, which holds 3:1.
- `sh-danger` is for destructive actions and errors, always with its word and the alert icon. It never sits next to an accent link.
- Use the ramps (`sh-stone-0` to `sh-stone-950`, `sh-signal-400` to `sh-signal-950`) only where no semantic token fits.

### Themes

**Concrete** (light) is the first theme and the fallback; **Night** (dark) is the second. The apps follow the OS appearance and set `data-theme="dark"` on the root; the site follows `prefers-color-scheme`. Never invert one theme by hand: every semantic token has a value for each. On Windows, when High Contrast is on (`forced-colors: active`), hand control back to the system colors; `bundle.css` already does this for its components.

### The indicator states

| State | Ring | Told apart by |
|---|---|---|
| Recording | `sh-state-recording`, a full ring | color |
| Hands-free | `sh-state-hands-free`, a ring with a gap at the top | shape |
| Writing | `sh-state-writing`, an ink ring that pulses | color and motion |
| A note | no ring; a short label in `sh-note-label` | the label |

Always name the state in words next to the indicator, in tooltips and in accessible names.

## Type

- Three families, all SIL Open Font License, all on Google Fonts: **Archivo** (`--font-ui`) for everything you read and operate, **Fragment Mono** (`--font-mono`) for labels, keys, metadata and code, **Bodoni Moda** italic (`--font-serif`) for the name and for words that were just spoken.
- Bundle the font files inside every app build; never rely on system fonts or a network request. The website loads them from Google Fonts with the stacks as fallbacks.
- **On the site** use the Web styles: `web-display` once per page for the hero line, `web-h1` for chapter heads, `web-h2` and `web-lead` under them, `web-body` for running text, `web-cta` on keycaps. Headings are Archivo 520 with tight negative tracking (-0.042em at the top), as on the landing page. Sizes are fluid: `clamp(min, N × u, max)` with `u = min(1vw, 1.6vh)`, so the composition keeps its proportions in short windows.
- **In the app** use the App styles: `app-title` for the screen title, `app-heading` for groups, `app-body` for all interface text, `app-strong` for button labels and the setting a row names, `app-small` for help under a control. Never set Archivo below weight 420 or 11 px.
- Mono `label` is the landing page's metadata voice: the app name beside dictated text, times, counts, "Network: Offline". Always in `sh-text-muted`. `code` is for terminal text and file paths.
- Serif `wordmark` sets the name until drawn logo files exist. `spoken` shows a dictated line as a specimen on the site, once per chapter. Never use the serif for interface text, buttons or headings.
- Figures are tabular everywhere (`font-variant-numeric: tabular-nums`, set on `.sh-root` and `.sh-app`).

## Space, layout and shape

- 4 px base: `sh-space-1` (4) to `sh-space-11` (192). Window content sits `sh-space-5` (24) in from its edges; groups are `sh-space-6` (32) apart.
- **Rows** carry most screens: a mono label column of `sh-row-label` (104 px), the content, an optional action on the right, a `sh-border` hairline below. Settings, History, Meetings and the site's spec lists all use them.
- The app is a sidebar (`sh-sidebar`, 200 px, on `sh-bg-sunken`) and one content column on `sh-bg`, at most 720 px wide for reading.
- **Site:** 12 columns, 24 px gutters, 1,200 px maximum; side margins 16, 32 and 64 px for phone, tablet and desktop (the hero runs wider, with `clamp(1rem, 3.4u, 6rem)` gutters). 96 to 192 px between sections on desktop. Text is left-aligned.
- **Radius** is a keycap corner: `sh-radius-sm` (4 px) for every key, button, input, card, row and the reminder; `sh-radius-xs` (2 px) for the LED and tags; `sh-radius-md` (8 px) for menus, popovers and the site's screenshot frame; `sh-radius-full` for the indicator only.
- **Depth** belongs to keys. `sh-key-primary` (4 px side) and `sh-key` (3 px side) at rest; `sh-key-primary-down` and `sh-key-down` when pressed, with the cap moved by `sh-travel-primary` or `sh-travel`. Floating things (menus, popovers, the reminder) use `sh-pop`. Cards and panels are flat: a ground change and a hairline.
- Control heights: `sh-control-sm` (28) for toolbars, menus and segmented controls, `sh-control-md` (32) by default, `sh-control-lg` (44) in onboarding and on touch, `sh-control-xl` (52) for the site CTA.

## Motion

Motion explains what changed, and then it stops.

- A key goes down in `sh-dur-press` on `sh-ease-press` and comes back up in `sh-dur-fast` on `sh-ease-settle`. Nothing bounces, overshoots or springs.
- Hover and focus: `sh-dur-fast`. Panels and the reminder enter in `sh-dur-slow` on `sh-ease-settle` (8 px up, fading in) and leave in `sh-dur-base` on `sh-ease-leave`.
- The indicator appears in 160 ms (92 % to 100 % scale, `sh-ease-settle`); its ring color crossfades in `sh-dur-fast`. The writing ring pulses from 100 % to 35 % opacity, `sh-dur-pulse` each way, on `sh-ease-breathe`.
- The caret blinks on `sh-dur-blink` in `sh-signal` while text is landing, then disappears.
- The word reveal (`sh-reveal`): each word from 0 to 100 % opacity, from a 4 px blur, 2 px rise, 240 ms, 40 ms stagger, done within `sh-dur-reveal`. Once per screen or page, on the hero line or on text that has just landed. Never on body text, never on scroll.
- The site may tie the key press and the landing words to scroll, as the landing page does. The app never animates on its own: only in answer to the key, the mic or the person.
- Under `prefers-reduced-motion: reduce` every duration is 0 ms, the pulse stops at full opacity and text simply appears. `bundle.css` handles this for its components.

## Iconography

- One icon set on every platform: [Lucide](https://lucide.dev/license) (ISC), or new icons drawn to its spec: 24 px grid, 1.5 px stroke, round caps and joins, no fills, in `currentColor`. SF Symbols are licensed for Apple platforms only, so the shared UI does not use them.
- Sizes: 16 px in rows, menus, buttons and the sidebar; 20 px in toolbars; 24 px on the site.
- Never draw microphones, waveforms, sound bars, orbs, sparkles, brains, robots, padlocks, shields or clouds.
- The 🤫 is never an icon. It appears only as the indicator, the app icon, the favicon and the tray or menu bar icon, always as the Noto Color Emoji artwork in the Indicator asset group (Apache License 2.0), never a typed emoji.
- The fn key itself is the brand's one drawn object. Use `sh-key` for it; never a photo of a keyboard.

## Building with this system

- **Tokens.** Every value is a CSS custom property: `--sh-*` for colors, spacing, radii, shadows, sizes, durations and easings; `--font-ui`, `--font-mono` and `--font-serif` for the families. Type styles are classes of the same names (`.app-body`, `.web-h1`, `.label`).
- **Components.** `components/bundle.css` holds every component as plain CSS classes with an `sh-` prefix; there is no script bundle, so the app can use any framework. Put `.sh-app` on the app's root (or `.sh-root` on a site section) to set the base font, color and ground. Each component below has a live preview and its markup.
- **Focus.** Keyboard focus is a 2 px solid ring in `sh-focus`, 2 px outside the element (`outline: 2px solid var(--sh-focus); outline-offset: 2px`). It holds 5:1 or better on every ground in both themes. Never remove it.
- **Platforms.** One UI, three operating systems. The Platforms section lists what changes per OS: window chrome, key names, the trigger key, the tray, the indicator's position and font rendering.

## Quick rules

| Do | Don't |
|---|---|
| Ink on concrete for everything static | Orange on anything that is not live |
| One `sh-signal` mark per view | Two signal marks, or signal as text by day |
| Keycaps with a side for things you press | Shadows on cards, panels or text |
| 4 px corners | Pills, 12 px cards, round buttons |
| Archivo for UI, Fragment Mono for labels, Bodoni italic for the name and spoken words | Serif headings, mono sentences, a fourth family |
| Lucide at 1.5 px on every OS | SF Symbols, Segoe icons or Material icons |
| The state named in words beside the indicator | A ring color on its own |
| shepetal, lowercase, everywhere | Shepetal, SHEPETAL, the shepetal app |

## Before you ship a screen or a page

1. Is there exactly one primary keycap, and at most one signal mark?
2. Is every color a semantic token, and does the screen work in Concrete and Night?
3. Search for an em dash. One is a failure.
4. Is shepetal lowercase everywhere?
5. Is every claim one of the claims, said as written, once?
6. Does every error say what happened and the next step?
7. Does every icon-only control have an accessible name, and does Tab reach everything with a visible ring?
8. Does it hold with reduced motion on, and at 125 % and 150 % display scaling on Windows?
9. Are the key names right for this platform?
