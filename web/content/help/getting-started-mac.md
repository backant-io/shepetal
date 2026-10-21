---
title: Getting started on Mac
description: Install Shepetal, grant the three permissions, and dictate your first sentence.
order: 1
---

# Getting started on Mac

You need a Mac with Apple Silicon and macOS 14 or later.

## Install

1. Download `Shepetal-<version>.pkg` from the [releases page](https://github.com/backant-io/shepetal/releases).
2. Open it. The installer is not signed by Apple yet, so macOS may refuse it the first time. Right-click it, choose **Open**, then **Open** again. If macOS offers no Open button, click **Done**, go to **System Settings > Privacy & Security**, click **Open Anyway** next to the Shepetal package, and confirm with your password.
3. Click through the installer. It puts Shepetal in Applications, sets the 🌐 key to Do Nothing (see below), turns on **Start at login**, and opens Shepetal.

Shepetal lives in the menu bar as 🤫. It has no Dock icon. A tiny 🤫 also sits in the bottom-left corner of your screen while it runs.

## The three permissions

The permissions window asks for three things. Grant all three:

| Permission | Why |
|---|---|
| **Microphone** | To hear you while you dictate. The mic is on only while you dictate. |
| **Input Monitoring** | To notice when you press and release fn. |
| **Accessibility** | To paste the text at your cursor. |

Click **Grant…** next to each one. Each row turns ✅ once it is on, and you don't need to restart. When all three are on, **Home** in the Shepetal window shows the fn key as watched.

## Sign in

Choose **Sign in to start your free trial…** in the 🤫 menu and sign in with Google. Your 30-day free trial starts, with no card. See [Trial and license](trial-and-license).

## The speech model

If the on-device speech recognition model is not on your Mac yet, the 🤫 menu offers the download (about 470 MB). You download it once. After that, dictation works with no internet connection.

## The 🌐 key is set for you

On a Mac, pressing 🌐 (fn) normally switches the keyboard language or opens the emoji picker, and that would get in the way of dictation. So the installer sets **System Settings > Keyboard > Press 🌐 key to** to **Do Nothing**. Shepetal checks it again at every launch and says so once next to 🤫 if it had to change it back. It touches no other system setting.

To put your old setting back, open **Open shepetal > Settings** and click **Restore 🌐 key setting**. That lasts until Shepetal starts again. Uninstalling Shepetal also restores it.

## Try it

Click into any text field, hold fn, say a sentence, and let go. The text appears at your cursor.

## Uninstall

Run `/Applications/Shepetal.app/Contents/Resources/uninstall.sh` in Terminal. It quits Shepetal, turns Start at login off, restores your 🌐 key setting and removes the app. Your recordings and history stay unless you add `--delete-data`.
