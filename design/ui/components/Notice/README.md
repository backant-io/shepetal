# Notice
An inline message that names a limit and the way around it, with the action that fixes it.

- **Provide:** `<div class="sh-notice" role="status">` (or `role="alert"` for errors) with a 16 px icon, `sh-notice-title` (what happened, one line), `sh-notice-body` (the next step) and optional `sh-notice-actions`.
- Add `sh-notice--danger` only when something failed and needs action now. Information and permissions use the plain notice.
- Warm through care, never through jokes: "Your recording is saved. Re-transcribe it from History when the mic is back."
- No toasts for errors. A toast only confirms an action that just happened ("Copied").
