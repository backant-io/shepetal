---
title: Getting started on Mac
description: Install Shepetal, grant the three permissions, and dictate your first sentence.
order: 1
---

# Getting started on Mac

You need a Mac with Apple Silicon and macOS 14 or later.

## Install

1. Download `Shepetal-<version>-mac.zip` from the [releases page](https://github.com/backant-io/shepetal/releases) and double-click it. You get `Shepetal.app`.
2. Drag `Shepetal.app` into your Applications folder before you open it.
3. Double-click it. Shepetal is not notarized by Apple yet, so macOS says it cannot verify the app. Click **Done**, open **System Settings > Privacy & Security**, scroll to **Security**, click **Open Anyway** next to Shepetal, and confirm with your password. You do this once per download.

Shepetal lives in the menu bar as 🤫. It has no Dock icon. A tiny 🤫 also sits in the bottom-left corner of your screen while it runs.

A one-click installer (`.pkg`) that also turns on Open at login is **coming soon**.

## The three permissions

On first launch the permissions window asks for three things. Grant all three:

| Permission | Why |
|---|---|
| **Microphone** | To hear you while you hold fn. The mic is open only while you dictate. |
| **Input Monitoring** | To notice when you press and release fn. |
| **Accessibility** | To paste the text at your cursor. |

Click **Grant…** next to each one. Each row turns ✅ once it is on, and you don't need to restart. When all three are on, the first line of the 🤫 menu reads "Hold fn to talk, double-tap for hands-free".

## The speech model

If the on-device speech recognition model is not on your Mac yet, the 🤫 menu offers a download (about 470 MB). This is a one-time download. After it, dictation works with no internet connection.

## The 🌐 key

On most Macs, pressing 🌐 (fn) switches the keyboard language or opens the emoji picker, which gets in the way of dictation. **Coming soon:** Shepetal sets **Press 🌐 key to** to **Do Nothing** for you on install and launch, tells you once next to 🤫, and lets you restore your old setting from the menu.

Until then, set it yourself: **System Settings > Keyboard > Press 🌐 key to > Do Nothing**.

## Start with your Mac

Choose **Open at login** in the 🤫 menu. If macOS asks for approval, allow Shepetal in **System Settings > General > Login Items**.

## Try it

Click into any text field, hold fn, say a sentence, and let go. The text appears at your cursor.
