# Hover Lens

Grab or translate any text on your screen — a game menu, a scanned PDF, a video subtitle, an app in a language you don't read.

macOS 15 or later. Apple Silicon and Intel.

## How to use it

| Shortcut | What it does |
|---|---|
| **⌘⇧2** | **Grab text.** You get macOS's own ⌘⇧4 crosshair: drag a box, or press Space and click a window. One line is copied straight away. More than one line and the words light up: drag across the ones you want, then press ⌘C to copy them. Nothing is selected to begin with; ⌘A selects everything, double-click picks a line. Esc or a click outside cancels. |
| **⌘⇧1** | **Translate.** Same crosshair. The translation is written over the original, each paragraph in the page's own colours, and you pick from it exactly like grabbing text — drag across words, then ⌘C to copy; double-click for a paragraph. Space flips to the original and back; Esc or a click outside closes. The target language is set in Settings. |

Both shortcuts can be changed in Settings. Esc cancels at any point.

## Languages

Text is read in any script the screen shows. Apple's Vision reads Latin, Cyrillic, Chinese, Japanese, Korean and the rest of its set; a bundled Tesseract reads what Vision can't — Hebrew, Arabic, Persian, the Indic scripts, Greek, Georgian, Armenian, Thai, Khmer, Ethiopic and more.

Translation is as fast as the language pack allows. With the offline Opus-MT pack for a language pair on the Mac, a draft translation appears almost at once (about a quarter of a second for several paragraphs), and Apple's on-device Translation — better, but about a second per paragraph — replaces it paragraph by paragraph as it finishes. The pack for a pair downloads on its own in the background the first time you translate it (roughly 150 MB); until then Apple's paragraphs appear one by one. Pairs Apple doesn't cover use the pack alone. Pressing ⌘⇧1 also starts loading the models while you drag.

## Privacy

The screen is captured only when you press a shortcut, using macOS's own screenshot tool. The capture lands in a private temporary file that is read and deleted immediately. Nothing you capture is kept, logged or sent anywhere. The only network use is downloading language packs, which happens on its own the first time you translate from a language; your text is never sent.

## Limitations

- Handwriting and vertical Japanese don't read reliably.
- Heavily stylised game fonts sometimes read badly or not at all.
- Offline translation between two languages that aren't English goes through English, which loses some nuance.

## Development

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated — never edit it by hand.

```sh
Scripts/build-tesseract.sh   # once: universal static Tesseract + models into Vendor/
xcodegen generate
xcodebuild -scheme HoverLens -destination 'generic/platform=macOS' build
swift test --package-path HoverLensKit --scratch-path ~/Library/Caches/HoverLensKit-build
```

The `--scratch-path` keeps SwiftPM's build out of an iCloud-synced folder, where Finder metadata breaks resource-bundle signing.

`HoverLensKit` holds OCR (Vision + Tesseract, reading order, the recognised-text model) and the offline translator (ONNX Runtime + Opus-MT), with no UI, tested from the command line against committed fixtures. The app on top is the menu-bar agent: hotkeys, the system screenshot capture, the word picker, the translation card, settings.

Everything native is linked statically for both architectures, so the app runs on any Mac with nothing installed.

## Licence

© Magicelk Labs. All rights reserved. Third-party licences (Tesseract, Leptonica, ONNX Runtime, Opus-MT models) are in `Vendor/licenses`, ship inside the app, and are shown in Settings › Acknowledgements.
