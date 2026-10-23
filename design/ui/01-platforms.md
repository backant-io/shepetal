# Platforms

One web UI, built once from this system, ships inside a desktop shell on three operating systems. Everything inside the window is identical on every platform: tokens, components, layout, copy. What changes is the frame around it and the words for keys. Keep that list short, and keep it here.

## What stays the same everywhere

- The window content: the sidebar, rows, keycaps, fields, the type scale and both themes.
- The icons (Lucide), the fonts (bundled Archivo, Fragment Mono and Bodoni Moda) and the indicator artwork (the Noto 🤫).
- Theme follows the OS appearance. The OS accent color is ignored: the brand's signal is the only accent.
- Reduced motion follows the OS setting on every platform.

## Window chrome

| | Mac | Windows | Linux |
|---|---|---|---|
| Title bar | Unified, 40 px, content drawn under it (hidden-inset style) | 32 px, drawn by the app over `sh-bg` | 46 px header bar drawn by the app (client-side decorations) |
| Window controls | Native traffic lights, top left, 14 px in | Native caption buttons (titleBarOverlay or equivalent), top right, 46 × 32 each | Close, and minimize/maximize only if the desktop's button layout asks for them; side from the desktop setting |
| Title | Centered, `app-strong` 13 px | Left, after the app icon, 12 px | Centered, `app-strong` 13 px |
| Window corners | System | System (rounded on Windows 11) | `sh-radius-md` if drawn by the app; system otherwise |
| Shadow | System | System | System; never draw one inside the window |

Use `.sh-titlebar` with `data-os="mac"`, `"windows"` or `"linux"`. Drag regions cover the whole bar except controls. Never draw fake traffic lights or caption buttons in a real build; the preview draws them only to show the spacing.

## Keys and shortcuts

| | Mac | Windows | Linux |
|---|---|---|---|
| Modifier | ⌘ | Ctrl | Ctrl |
| Shown as | `⌘V` (no plus, symbol first) | `Ctrl+V` | `Ctrl+V` |
| Option / Alt | ⌥ | Alt | Alt |
| Paste after dictation | ⌘V | Ctrl+V | Ctrl+V (Ctrl+Shift+V in terminals) |
| The dictation key | `fn` | The key chosen in onboarding | The key chosen in onboarding |

Show keys with `.sh-kbd`: one cap per key, joined with `.sh-kbd-plus` on Windows and Linux. The dictation key is the only `.sh-kbd--signal`. Copy that names the key uses the name printed on it.

## Menu bar and tray

- **Mac:** the 🤫 sits in the menu bar. Clicking it opens the 🤫 menu (`.sh-menu`).
- **Windows:** the 🤫 sits in the notification area (16, 20, 24 and 32 px files). A left click opens the same menu, anchored above the taskbar.
- **Linux:** a StatusNotifierItem (AppIndicator) with the same menu. GNOME shows it only with the AppIndicator extension, so the app keeps a window reachable from the launcher as well.
- The menu is the same everywhere: the state in words at the top, then Home, History, Meetings, Settings, then Quit shepetal.

## The indicator's corner

The indicator sits `sh-space-2` (8 px) in from the bottom-left corner of the screen's work area, in its own always-on-top, click-through window (`sh-z-overlay`). "Work area" means above the Windows taskbar, the GNOME dock or the Mac Dock when they sit at the bottom. On several displays it follows the display with the focused window. The meeting reminder opens above it, left-aligned with it.

## Text and pixels

- Bundle the woff2 files and load them with `@font-face` from the app; never fall back to the system face in a shipped build.
- Windows renders thin weights poorly at small sizes: the App styles never go below weight 420 or 11 px. Check every screen at 100 %, 125 % and 150 % display scaling.
- Hairlines are 1 CSS px. At 125 % and 150 % they land on fractional device pixels; that is expected. Never use 0.5 px borders.
- Scrollbars: overlay on Mac; on Windows and Linux style them thin (8 px) in `sh-border-strong` on transparent, widening on hover.

## Words for the system

| | Mac | Windows | Linux |
|---|---|---|---|
| The file manager | Finder | File Explorer | your file manager |
| Settings app | System Settings | Settings | your system settings |
| Show the folder | Show in Finder | Show in File Explorer | Open folder |
| Quit | Quit shepetal | Exit shepetal | Quit shepetal |

Permission prompts name the setting exactly as the OS shows it, in one sentence that says why: "Accessibility lets shepetal paste your text where your cursor is."

## The website

The site uses the same tokens and components with the Web type styles. Until a platform ships, the site names only the platforms that have: "For Mac." today, with no roadmap line. Once more than one ships, downloads are one keycap per platform: `Download for Mac`, `Download for Windows`, `Download for Linux`. Detect the visitor's OS and make that one the primary keycap; the other two are secondary keycaps beside it. The landing page's scroll story (the key pressed by scrolling, words flying into Mail, Chat, Code, Terminal and Doc) is the site's signature; the app never borrows it.
