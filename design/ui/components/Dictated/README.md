# Dictated
Text that has just been spoken: it lands word by word, a signal caret blinking at its end, and on the site it is set in the serif.

- **Provide:** `<p class="sh-reveal">` with each word in a `<span style="--i:N">` (N from 0), and `<span class="sh-caret" aria-hidden="true"></span>` after the last word while text is still landing. Remove the caret when it is done.
- On the site, add `sh-spoken` (Bodoni Moda italic) to show a dictated line as a specimen, once per chapter. In the app, landed text stays in `app-body`.
- The reveal runs once, on the line that just landed, within `sh-dur-reveal`. Never on body text, never on scroll in the app.
- Under reduced motion the words simply appear.
