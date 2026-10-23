# Indicator
The 🤫 in the bottom-left corner of the screen, whose ring says what shepetal is doing.

- **Provide:** `<span class="sh-indicator" data-state="recording" role="img" aria-label="Recording"><img src="(the 🤫 from the Indicator asset group)" alt=""></span>`, with `data-state` set to `recording`, `hands-free`, `writing` or `note`, and the state's word beside it wherever people can read it.
- On screen it is `sh-indicator` (18 px) in its own always-on-top, click-through window, `sh-space-2` in from the work area's bottom-left corner (Platforms). Add `sh-hush` when it appears.
- Recording: a full signal ring. Hands-free: a signal ring with a gap. Writing: an ink ring that pulses. A note: no ring, a short label (`sh-indicator-label`, eight words or fewer).
- `sh-indicator--lg` (44 px) is for the site, onboarding and help pictures, always captioned with the state.
- Always the Noto 🤫 artwork, never a typed emoji. Call it "the indicator", never the orb, bubble, dot or widget.
