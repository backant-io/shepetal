# TextField
A labelled text input on the field ground, with optional help and an error that gives the next step.

- **Provide:** `<div class="sh-field"><label class="sh-field-label" for="id">Label</label><input class="sh-input" id="id"> <p class="sh-field-help" id="id-help">Help</p></div>`, with `aria-describedby` pointing at the help or error.
- Errors: set `aria-invalid="true"` on the input and replace the help with `<p class="sh-field-error">` holding the alert icon and one line that says what happened and what to do.
- Labels are nouns in sentence case ("Word", "Spoken as"). Placeholders show an example, never the label.
- Fields sit on `sh-bg-field` with a `sh-border-strong` edge (3.3:1). Never borderless on concrete.
