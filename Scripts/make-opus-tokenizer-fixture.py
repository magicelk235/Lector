#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["sentencepiece==0.2.2"]
# ///
"""Builds the tiny Marian tokenizer fixture used by OpusMTTokenizerTests.

    uv run Scripts/make-opus-tokenizer-fixture.py

A real Opus-MT tokenizer is 3 MB; this one is a few kilobytes but exercises the same
paths: a unigram model trained by the reference SentencePiece library, with a compiled
normalisation map (full-width forms, ligatures, a two-character composition, odd spaces)
standing in for the nmt_nfkc map the real models carry, and a Marian-style vocab.json with
a `>>xx<<` target token. It prints the ids the reference implementation produces for the
test sentence; the test pins those.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import sentencepiece as spm

OUT = Path(__file__).resolve().parent.parent / "HoverLensKit/Tests/HoverLensKitTests/Fixtures/opus-tokenizer"

CORPUS = """\
Hello world, how are you today?
The quick brown fox jumps over the lazy dog.
Translation keeps every line of the text in its place.
Guten Morgen, wie geht es dir heute?
Bonjour le monde, comment allez-vous ? Café, élève, naïve.
שלום עולם, מה שלומך היום?
מה השעה עכשיו? אני לומד עברית.
مرحبا بالعالم، كيف حالك اليوم؟
Γεια σου κόσμε, τι κάνεις σήμερα;
Привет, мир! Как дела сегодня?
नमस्ते दुनिया, आप कैसे हैं?
สวัสดีชาวโลก คุณสบายดีไหม
你好世界，今天好吗？
The office has fifty flowers and five fine fields.
"""

# Source code points, a tab, then what they become. SentencePiece compiles these into
# the same double-array trie format the nmt_nfkc rules use.
RULES = [
    *[(f"{cp:04X}", f"{cp - 0xFEE0:04X}") for cp in range(0xFF01, 0xFF5F)],  # Ａ → A
    ("FB01", "66 69"),       # ﬁ → fi
    ("FB02", "66 6C"),       # ﬂ → fl
    ("00A0", "20"),          # no-break space
    ("3000", "20"),          # ideographic space
    ("2026", "2E 2E 2E"),    # … → ...
    ("0065 0301", "00E9"),   # e + combining acute → é, a two-character match
]

SENTENCE = "  Ｈｅｌｌｏ\u00a0 world…  ﬁne cafe\u0301 😀😀 שלום  "
TARGET_TOKEN = ">>heb<<"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    rules = OUT.parent / "opus-tokenizer-rules.tsv"
    rules.write_text("".join(f"{src}\t{dst}\n" for src, dst in RULES))
    model = io.BytesIO()
    try:
        spm.SentencePieceTrainer.train(
            sentence_iterator=iter(CORPUS.splitlines()),
            model_writer=model,
            model_type="unigram",
            vocab_size=300,
            hard_vocab_limit=False,
            character_coverage=1.0,
            normalization_rule_tsv=str(rules),
            bos_id=-1,
            eos_id=1,
            unk_id=0,
            minloglevel=2,
        )
    finally:
        rules.unlink()
    (OUT / "source.spm").write_bytes(model.getvalue())

    processor = spm.SentencePieceProcessor(model_proto=model.getvalue())
    # Marian's layout: </s> and <unk> first, the pieces, the target tokens, <pad> last.
    vocabulary = {"</s>": 0, "<unk>": 1}
    for index in range(processor.get_piece_size()):
        piece = processor.id_to_piece(index)
        if not (processor.is_control(index) or processor.is_unknown(index)):
            vocabulary.setdefault(piece, len(vocabulary))
    vocabulary[TARGET_TOKEN] = len(vocabulary)
    vocabulary["<pad>"] = len(vocabulary)
    (OUT / "vocab.json").write_text(json.dumps(vocabulary, ensure_ascii=False, indent=0))

    pieces = processor.encode(SENTENCE, out_type=str)
    ids = [vocabulary[TARGET_TOKEN]] + [vocabulary.get(p, vocabulary["<unk>"]) for p in pieces] + [0]
    print("pieces:", json.dumps(pieces, ensure_ascii=False))
    print("ids:   ", ids)


if __name__ == "__main__":
    main()
