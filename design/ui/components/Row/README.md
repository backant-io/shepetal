# Row
The landing page's spec row, used for settings and lists: a mono label column, the content, an optional action, a hairline below.

- **Provide:** `<div class="sh-rows">` around rows of `<div class="sh-row"><span class="sh-row-label">Label</span><div class="sh-row-main"><span class="sh-row-title">…</span><span class="sh-row-help">…</span></div><div class="sh-row-action">control</div></div>`.
- The label is a short mono word in `sh-text-muted` (Shortcut, Microphone, Network). The title says the current value or the setting; the help says what it does, in one line.
- One control per row, on the right. Keep the label column at `sh-row-label` so rows on a screen line up.
- Below 480 px the label moves above the content.
