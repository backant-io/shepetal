---
title: Linux and Windows
description: Shepetal on Linux (beta) and Windows (coming).
order: 10
---

# Linux and Windows

## Linux (beta)

Shepetal for Linux is an early beta. It works on X11 and Wayland, uses the same gestures as the Mac (hold fn to talk, double-tap for hands-free), keeps every recording on your machine, and runs speech recognition locally. It has not been tested widely on real desktops yet, and for now you build it from source. Packages are coming soon.

- Build and setup steps are in the [Linux README](https://github.com/backant-io/shepetal/tree/main/linux).
- Your user needs to be in the `input` group so Shepetal can see the fn key.
- Many laptops handle fn in their firmware and never pass it on. Shepetal tells you when it can't see fn and asks you to choose another key, for example `SHEPETAL_KEY=rightalt`. It never switches keys silently.
- The 🤫 indicator and meetings on Linux are coming soon.

## Windows

**Coming.** There is no Windows release yet. Windows keyboards don't report fn, so on Windows you'll hold **Ctrl+Win** to talk. Like the Mac, speech recognition will run on your PC, and nothing you say will leave it.
