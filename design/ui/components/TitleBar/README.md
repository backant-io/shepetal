# TitleBar
The top of every app window, drawn by the app over `sh-bg` with the platform's own window controls.

- **Provide:** `<header class="sh-titlebar" data-os="mac|windows|linux">` with `sh-titlebar-title` and, on Windows and Linux, the space the native controls take (`sh-caption`). Mark the bar as the drag region.
- Mac: 40 px, traffic lights 14 px from the left, title centered. Windows: 32 px, caption buttons on the right, title left. Linux: 46 px header bar, title centered, buttons on the side the desktop's button layout names.
- Use the native controls in shipped builds. The preview draws them only to show where they sit.
- The title is the screen name. The About window's title is the wordmark.
