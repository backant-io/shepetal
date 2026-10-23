# shepetal UI assets

Copied into the app as SwiftPM resources (`Shepetal_Shepetal.bundle/Assets`). Each license file ships next to its files.

## Fonts (SIL Open Font License 1.1)

From the official [google/fonts](https://github.com/google/fonts) repository at commit
`e7db6ca603fd4862010383ff17ffd6cc4ffac1c0`, unmodified, renamed only to drop the axis brackets:

| File | Upstream path | License |
|---|---|---|
| `Fonts/Archivo/Archivo.ttf` | `ofl/archivo/Archivo[wdth,wght].ttf` (variable: wdth 62 to 125, wght 100 to 900) | `Fonts/Archivo/OFL.txt` |
| `Fonts/FragmentMono/FragmentMono-Regular.ttf` | `ofl/fragmentmono/FragmentMono-Regular.ttf` | `Fonts/FragmentMono/OFL.txt` |
| `Fonts/BodoniModa/BodoniModa-Italic.ttf` | `ofl/bodonimoda/BodoniModa-Italic[opsz,wght].ttf` (variable: opsz 6 to 96, wght 400 to 900) | `Fonts/BodoniModa/OFL.txt` |

## Icons (ISC)

[Lucide](https://github.com/lucide-icons/lucide) release `1.56.0` (tag commit `440a1e1dfb1e712505308da46bead3c28b1f1398`),
`icons/<name>.svg`, unmodified. License: `Icons/LICENSE.txt`. The app strokes them at 1.5 pt (Icons.swift).
To add one: copy `icons/<name>.svg` from the same tag and add a case to `SHIconName`.

## The indicator artwork (Apache License 2.0)

`shush.svg` is `design/ui/assets/Indicator/shush.svg`, the 🤫 (U+1F92B) from Noto Color Emoji by Google.
`shush.png` is that file rendered at 256 x 256, unmodified otherwise. License and notice: `emoji-LICENSE-Apache-2.0.txt`,
`emoji-NOTICE.txt`.
