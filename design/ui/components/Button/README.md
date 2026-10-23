# Button
A keycap: the one control people press, with a side that shows it can go down.

- **Provide:** a `<button>` (or `<a href>` for navigation) with `class="sh-btn"` plus one variant: `sh-btn--primary`, none for secondary, `sh-btn--quiet`, `sh-btn--danger`. Sizes: `sh-btn--sm` (28), default (32), `sh-btn--lg` (44), `sh-btn--xl` (52, the site CTA). An optional 16 px Lucide icon goes before the label; icon-only buttons need `aria-label`.
- **One primary keycap per view.** It is the action the screen exists for: "Try 30 days free" on the site, "Record" in the reminder, "Continue" in onboarding.
- Secondary keycaps for every other action; quiet buttons for toolbar and row tools where a cap would be noise.
- Danger is a secondary keycap with red text and a verb that names what goes: "Delete recording". Never a red fill.
- `sh-btn--signal` is reserved for the moment something is live (the reminder's Record while a call is starting). Never as a static call to action.
- Labels say exactly what happens, in sentence case, two or three words. No "Click here", no "Submit".
- Keep the margin under each keycap: it is the room its side needs.
