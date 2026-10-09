# Lector

Grab or translate any text on your Mac's screen: a game menu, a scanned PDF, a
video subtitle, an app in a language you don't read.

Lector sits in the menu bar. Press ⌘⇧2 to copy text from any part of the
screen, ⌘⇧1 to read it translated right where it is, or ⌘⇧9 to keep an area
translated as its text changes. All three open macOS's own ⌘⇧4 crosshair, and
Lector reads and translates the text on your Mac.

## Requirements

- macOS 15 or later, on Apple Silicon or Intel.
- The Screen Recording permission. Lector asks for it the first time it runs,
  and macOS needs the app relaunched after you grant it. Until then Lector is
  locked: its menu offers only to allow it. Lector doesn't need Accessibility.

## Install

Download [Lector.dmg](https://github.com/magicelk235/Lector/releases/latest/download/Lector.dmg),
open it and drag Lector to Applications. Lector updates itself: from the second
launch it asks whether to check for updates, and then installs them in the
background. Settings › General can turn that off or check now.

## Grab text with ⌘⇧2

You get the ⌘⇧4 crosshair. Drag a box around the text, or press Space and click
a window.

A single line goes straight to the clipboard. With more than one line, the words
light up so you can pick the ones you want: drag across them and press ⌘C.
Nothing is selected at first. ⌘A selects everything, and a double-click picks a
whole line. Lines that wrap are copied as one paragraph, without the screen's
line breaks. Esc or a click outside cancels. A small bar under the capture lists
the keys.

Press Tab to translate what you grabbed, right there. Lector doesn't capture or
read it again, and from then on it works like ⌘⇧1.

## Translate with ⌘⇧1

Same crosshair. Lector paints the translation over the original, a bit like
Google Lens: each paragraph is covered in its own background colour and
rewritten in a matching text colour. You copy from it the way you grab text, by
dragging across words and pressing ⌘C, or by double-clicking a paragraph. ⌘C
with nothing selected copies all of it. Space switches between the translation
and the original, and ⌘C copies whichever one you're looking at. Esc or a click
outside closes it.

A small bar under the capture says what it was translated from and into, such as
"French, Japanese +5 → Hebrew", and lists these keys. While a language pack
downloads, it shows the progress. If a language could only be translated by the
offline many-language pack, which gives a rough result (Persian, for example),
the bar says so.

The translation keeps the original's look as far as it can: the same size for
text of the same size, bold where the original is bold, headings above body
text, buttons' labels centred on their buttons. A translation that's longer than
its original first uses the empty space around it, and is only cut short with
"…" when there's none (copying still gives the whole of it). Into Hebrew or
Arabic, a column of text keeps one shared right edge.

Each paragraph is translated from its own language, so a chat in three
languages comes out as three translations. Text that's already in your
language stays as it is, and so do times, prices, keyboard shortcuts, code and
web addresses. Lines that wrap are joined back into sentences, including words
broken with a hyphen, and neighbouring paragraphs are translated together, so a
label like "Save" comes out as the button and not the verb "rescue".

If Lector gets the language wrong, press Tab to translate from the next likely
language, or ⇧Tab to go back. After the last one, Lector goes back to
detecting it. Lector remembers your choice for the app you captured from, so a
game in Japanese stays Japanese next time. The remembered language only decides
text that Lector can't tell for itself, such as a short label or kanji with no
kana. Settings › Translation lists these choices: change or remove one there, or
add an app before you capture from it.

Choose the language to translate into from the menu bar (Translate Into), in
Settings › Translation or in the Welcome Guide. Each lists the likeliest first:
the one you use now, those you've translated into lately, your Mac's languages
and those of its region, such as Hebrew and Arabic in Israel. Chinese is offered
as Simplified and Traditional. You can change all three shortcuts in
Settings › General.

## Live translation with ⌘⇧9 (beta)

Draw around game dialogue, video subtitles or any part of the screen whose
text changes. Lector keeps that area translated in place: when the text changes,
the new translation appears over it, usually within a second. Lines it has
translated before come back at once. The translation doesn't take clicks or
keys, so the game or video underneath keeps working.

Lector only reads the area again when something in it changes, and it waits
for a fade or a scroll to finish first, so a still screen costs almost nothing.
Press ⌘⇧9 again or Esc to stop, or choose Stop Live Translation from the menu
bar. Live translation comes with the Translate plan.

Live translation is in beta. A subtitle that's on screen for less than about a
second can be gone before its translation shows up, and over moving video the
last line's translation can stay up for a moment after the next line appears.
Stylised game fonts are sometimes misread, which comes out as an odd
translation.

## Plans

| | Free | Text ($9) | Translate ($15) |
|---|---|---|---|
| Grabs | 100 a month | Unlimited | Unlimited |
| Translations | 10 a month | 30 a month | Unlimited |
| Live translation (beta) | No | No | Yes |

Text and Translate are one-time purchases from
[Gumroad](https://magicelk235.gumroad.com/l/lector). A Text license can be
upgraded to Translate for $6 with the
[upgrade](https://magicelk235.gumroad.com/l/lector-upgrade). Paste the key from
your receipt into Settings › License; for an upgrade, enter the Text key first,
then the upgrade key.

A grab counts once text is found, and a translation counts when it starts,
whether from ⌘⇧1 or Tab in the word picker. Counts start over on the first of
each month. When you reach a limit, the shortcut opens the License window
instead of the crosshair; a capture already under way always finishes. To move
a license to another Mac, remove it in Settings › License and enter it there.

## Languages

Lector reads whatever script is on screen, and a page that mixes scripts is read
line by line in each one. Apple's Vision handles Latin, Cyrillic, Chinese,
Japanese, Korean and the rest of its set, including short labels such as
menu items. A bundled Tesseract reads the scripts Vision can't, including
Hebrew (with or without vowel points), Arabic, Persian, Urdu, the Indic scripts,
Greek, Georgian, Armenian, Thai, Khmer and Ethiopic. A full Retina page is read
in about half a second.

Serbian and Macedonian are told apart from Russian and Bulgarian by their own
letters, and Persian and Urdu from Arabic the same way.

Translation uses two engines. Apple's on-device Translation gives the better
result but takes about a second per sentence. An offline Opus-MT language pack
is much faster: a few paragraphs take about a quarter of a second and a full
screen of text about half a second, with the shortest paragraphs appearing
first. Apple's translation then replaces the draft as it arrives.

A pack is 100–250 MB. Lector downloads one on its own only when it's the only
way to translate a language, because Apple's Translation doesn't support it.
To also get instant drafts for languages Apple does translate, turn on Download
packs for instant drafts in Settings › Translation. That list shows each pack,
the languages it covers and its size, and can remove any of them. At most two
packs stay loaded in memory, and they're let go after three minutes without use.

Lector starts loading the models as soon as you press a shortcut, while you're
still dragging, and starts translating as soon as the text is read. Text it has
translated since you opened it, in the same capture or another one, shows up
straight away. It's kept in memory only and is gone when Lector quits.

## Privacy

Lector captures the screen only when you press one of its shortcuts, and it uses
macOS's screenshot tool to do it. The capture goes to a private temporary file
that Lector reads and deletes straight away. Live translation watches only the
area you drew, only until you stop it, and reads it in memory without saving
anything. Nothing you capture is kept, logged or sent anywhere, and there are no
analytics. Lector stores only its settings, such as the language you picked for
an app, the last few languages you translated between, to offer them first, your
license key, and how many grabs and translations you've made this month; never
the text itself.

Lector downloads language packs from Hugging Face, only as described under
Languages. If you enter a license key, Lector sends that key to Gumroad to check
it, when you enter it and again at each launch. A key Gumroad has confirmed
keeps working for 30 days without a connection. If you allow update checks,
Lector asks GitHub once a day whether there's a new version. Your text never
leaves the Mac.

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
