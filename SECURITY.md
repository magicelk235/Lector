# Security Policy

## Supported Versions

Lector is a rolling release. Only the latest version on the `main` branch and
the most recent published build get security fixes. If you're on an older
build, update before reporting.

| Version        | Supported          |
| -------------- | ------------------ |
| Latest release | :white_check_mark: |
| Older builds   | :x:                |

## Reporting a Vulnerability

Please don't open a public GitHub issue for a security vulnerability. Report it
privately instead:

- Open a draft advisory at
  <https://github.com/magicelk235/Lector/security/advisories/new>. This is the
  preferred route.
- Or email yehonatan.2350@icloud.com with the subject line `SECURITY: lector`.

Include:

- What the vulnerability is and what an attacker could do with it.
- Steps to reproduce, with a proof of concept if you have one.
- The Lector version, your macOS version, and your Mac's architecture.

## What to Expect

You'll get an acknowledgement within 5 business days, then an assessment. If
the issue is confirmed, you'll get a timeline for the fix, and most fixes ship
in the next release. You'll be credited in the release notes unless you'd
rather stay anonymous.

Please allow a reasonable window for a fix to ship before you disclose anything
publicly.

## Scope Notes

Lector is an unsandboxed menu-bar app, built with the hardened runtime and
distributed directly rather than through the App Store. It holds the Screen
Recording permission and registers global hot keys. When you press a shortcut,
it captures part of the screen with macOS's screenshot tool, reads the text with
Apple's Vision and a bundled Tesseract, and translates it with Apple's
Translation or an offline Opus-MT model running on ONNX Runtime.

These are in scope:

- Anything that lets the capture, its temporary file, or the recognised text
  outlive the shortcut, reach another process, or leave the Mac.
- Crafted on-screen content, such as an image, font, or page, that crashes
  Lector or runs code in it through Vision, Tesseract, Leptonica, or the
  translation path.
- Language pack downloads. Packs come from Hugging Face at pinned revisions and
  are checked against a size and SHA-256 hash before use. A way to get Lector
  to load a model that fails those checks, or to write outside its Application
  Support folder, is in scope.
- Abuse of the Screen Recording grant or the global hot keys by another app
  through Lector.

Bugs in Tesseract, Leptonica, or ONNX Runtime themselves belong upstream. Tell
us as well if Lector ships an affected version.

Don't put real screenshots of private content in a report. Use a test image or
redact it.
