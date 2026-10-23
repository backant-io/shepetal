# Toggle
A switch drawn as a small keycap that slides across and lights its LED when on.

- **Provide:** `<label class="sh-toggle"><input type="checkbox" role="switch"><span class="sh-toggle-track" aria-hidden="true"></span>Label</label>`. The native checkbox carries state, focus and the accessible name.
- Use it for settings that take effect at once. For choices that wait for a Save, use a checkbox.
- Off: the cap on the left, an ink well. On: the cap on the right on `sh-primary-fill`, the LED in `sh-signal`. The LED is the toggle's only signal mark; a screen of toggles is the one place more than one may show.
- Labels name the thing that is on: "Record meetings when I say yes", never "Enable meeting recording".
