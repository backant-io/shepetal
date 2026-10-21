---
title: Privacy
description: What never leaves your Mac, and what signing in sends.
order: 8
---

# Privacy

## What never leaves your Mac

- **Your voice.** Speech recognition runs on your Mac. Audio is never uploaded.
- **Your text.** What you dictate is pasted on your Mac and kept in your history there.
- **Your recordings and history**, including the app and page address of each dictation. They live in `~/Library/Application Support/Shepetal`, readable only by your user account.
- **Your meetings.** Recording, transcripts and summaries all happen on your Mac.

Turning speech into text, and writing meeting summaries, makes no network request.

## When Shepetal uses the internet

- **The one-time speech model download**, when you choose it from the 🤫 menu.
- **Sign-in and the license check**, at launch and every 24 hours. It never happens while you dictate.
- **Checkout** and the **Help center** open in your browser. **Send feedback…** opens an email.

## What sign-in sends

Sign-in is only for your license.

- You sign in with Google on shepetal.backant.io. Shepetal stores your email address, when your trial started, and whether you have bought a license.
- The app gets a private access token and keeps it in your Mac's Keychain. Only a scrambled (hashed) copy of it is stored on our side. It stops working when you sign out, or after 90 days without use.
- When the app checks your license, it sends only that token. The answer is your license status, trial end date and email.
- Payment goes through Stripe. Your card details go to Stripe, not to us.

None of your audio, text, history or meetings is part of this.
