# Lector

Grab or translate any text on your Mac's screen: a game menu, a scanned PDF, a
video subtitle, an app in a language you don't read.

Lector sits in the menu bar. Press ⌘⇧2 to copy text from any part of the
screen, or ⌘⇧1 to read it translated right where it is. Both shortcuts open
macOS's own ⌘⇧4 crosshair, and Lector reads and translates the text on your
Mac.

## Requirements

- macOS 15 or later, on Apple Silicon or Intel.
- The Screen Recording permission. Lector asks for it the first time it runs,
  and macOS needs the app relaunched after you grant it. Lector doesn't need
  Accessibility.

## Grab text with ⌘⇧2

You get the ⌘⇧4 crosshair. Drag a box around the text, or press Space and click
a window.

A single line goes straight to the clipboard. With more than one line, the words
light up so you can pick the ones you want: drag across them and press ⌘C.
Nothing is selected at first. ⌘A selects everything, and a double-click picks a
whole line. Esc or a click outside cancels.

## Translate with ⌘⇧1

Same crosshair. Lector paints the translation over the original, a bit like
Google Lens: each paragraph is covered in its own background colour and
rewritten in a matching text colour. You copy from it the way you grab text, by
dragging across words and pressing ⌘C, or by double-clicking a paragraph. Space
switches between the translation and the original. Esc or a click outside
closes it.

Choose the language to translate into in Settings › Translation. You can change
both shortcuts in Settings › General.

## Languages

Lector reads whatever script is on screen. Apple's Vision handles Latin,
Cyrillic, Chinese, Japanese, Korean and the rest of its set. A bundled Tesseract
reads the scripts Vision can't, including Hebrew, Arabic, Persian, the Indic
scripts, Greek, Georgian, Armenian, Thai, Khmer and Ethiopic.

Translation uses two engines. Apple's on-device Translation gives the better
result but takes about a second per paragraph. An offline Opus-MT language pack
is much faster, with a draft of several paragraphs in about a quarter of a
second, and Apple's translation then replaces the draft one paragraph at a time.
The pack for a language pair is roughly 150 MB and downloads in the background
the first time you translate that pair. Until it's there, Apple's paragraphs
appear one by one. Pairs that Apple doesn't support use the pack alone. Settings
› Translation lists the packs you have and can remove them.

Lector starts loading the models as soon as you press ⌘⇧1, while you're still
dragging.

## Privacy

Lector captures the screen only when you press one of its shortcuts, and it uses
macOS's screenshot tool to do it. The capture goes to a private temporary file
that Lector reads and deletes straight away. Nothing you capture is kept, logged
or sent anywhere, and there's no history and no analytics.

The only thing Lector downloads is language packs, from Hugging Face. Your text
never leaves the Mac.

## Limitations

- Handwriting and vertical Japanese don't read reliably.
- Heavily stylised game fonts sometimes read badly or not at all.
- Offline translation between two languages that aren't English goes through
  English, which loses some nuance.

## Security

Please report vulnerabilities privately, as described in
[SECURITY.md](SECURITY.md), and not in a public issue.

## License

Licensed under the [PolyForm Shield License 1.0.0](LICENSE). Copyright (c) 2026
Yehonatan Cohen (magicelk235). You may use, modify and share Lector, but you may
not use it to build a product that competes with Lector or with the author's
other products.

Tesseract, Leptonica, ONNX Runtime and the Opus-MT models keep their own
licenses. Those are in `Vendor/licenses`, ship inside the app, and are shown in
Settings › Acknowledgements.
