#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pycountry"]
# ///
"""Regenerates LectorKit's table of downloadable Opus-MT translation models.

    uv run Scripts/generate-opus-mt-catalog.py

Opus-MT (Helsinki-NLP, CC-BY 4.0) publishes PyTorch weights; the app needs ONNX. Several
Hugging Face accounts publish ONNX exports of those same models, so this script walks them,
keeps one export per Helsinki model, pins it to the commit it saw, and writes the result to
OpusMTCatalog.swift. The app never asks the network which models exist: this table is the
whole answer, which is what lets it say "supported, 115 MB to download" while offline, and
the pinned commit means a later push to one of those repositories cannot break a shipped
build.

Accounts are tried in order of trust. Xenova and onnx-community belong to Hugging Face's own
transformers.js effort; the others are individual exports used only for models the first
two never converted. Every export is checked against the Helsinki original before it is
accepted: its tokenizer files must be byte-identical and its config must describe the same
network, so an account cannot swap in a different model under the right name.

Responses are cached under ~/.cache/lector-opus-catalog, so a rerun is quick and does
not trip the Hub's rate limit (500 API calls per five minutes, anonymously).
"""

from __future__ import annotations

import datetime
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import pycountry

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "LectorKit/Sources/LectorKit/Translate/OpusMTCatalog+Models.swift"
CACHE = Path(os.environ.get("OPUS_CATALOG_CACHE", "~/.cache/lector-opus-catalog")).expanduser()
HUB = "https://huggingface.co"

# Most trusted first. Among exports of the same Helsinki model the earliest account wins.
PUBLISHERS = ["Xenova", "onnx-community", "fintutto", "TigreGotico", "R4kSo1997"]

# One model's download, all files together. Opus-MT's "tc-big" models run 500-900 MB even
# quantised, five times a base model, for a quality gain most screen text does not need;
# where a big model is the only direct route, the multilingual pivot serves instead.
MAX_MODEL_BYTES = 400_000_000

# Models whose name collides with a real language code: "jap" is OPUS's label for Japanese
# Bible text (ISO 639-3 "jap" is Jaruára), and the "ja" models cover Japanese properly.
SKIP_MODELS = {"opus-mt-en-jap", "opus-mt-jap-en"}

# Opus labels some languages by an individual code where the app knows the macrolanguage.
INDIVIDUAL_TO_MACRO = {
    "cmn": "zho", "arb": "ara", "pes": "fas", "swh": "swa", "zsm": "msa", "zlm": "msa",
    "npi": "nep", "ekk": "est", "lvs": "lav", "khk": "mon", "uzn": "uzb", "azj": "aze",
    "pbt": "pus", "ydd": "yid", "gug": "grn", "plt": "mlg", "nor": "nob", "no": "nb",
    "hbs": "hbs", "sh": "hbs",
}

# Group labels Opus uses in model names; their members come from the model card.
GROUP_CODES = {
    "mul", "ROMANCE", "bat", "gem", "gmw", "gmq", "sla", "zls", "zle", "zlw", "itc", "cel",
    "sem", "inc", "iir", "ine", "urj", "fiu", "trk", "tur", "afa", "alv", "art", "aav",
    "bnt", "ccs", "cpf", "cpp", "cus", "dra", "euq", "grk", "map", "mkh", "nic", "phi",
    "roa", "sal", "sit", "sq", "tai", "tut", "wen", "zhx", "poz", "pqe", "pqw", "cau",
    "crp", "esx", "ira", "kab", "nah", "ber", "SCANDINAVIA", "NORWAY", "NORTH_EU", "CELTIC",
    "FI_ZH", "ZH", "de_nl", "en_el_es_fi", "aed", "jpx", "gil", "bem", "ceb", "chk",
}

# A multilingual model covers so many languages that it is a last resort for each one.
MULTILINGUAL_THRESHOLD = 60


# ---------------------------------------------------------------------------------------
# Network, politely.

_last_api_call = 0.0


def _cache_path(url: str) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    return CACHE / re.sub(r"[^A-Za-z0-9._-]+", "_", url)[-200:]


def _get(url: str, *, api: bool, allow_missing: bool) -> tuple[bytes | None, dict]:
    """The body and headers of `url`, retrying through rate limits, server errors and
    dropped connections for up to about ten minutes."""
    global _last_api_call
    last_error: Exception | None = None
    for attempt in range(12):
        if api:
            # 500 calls per 300 s is the anonymous budget; stay under it.
            wait = 0.65 - (time.time() - _last_api_call)
            if wait > 0:
                time.sleep(wait)
            _last_api_call = time.time()
        backoff = min(60, 2 ** (attempt + 1))
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "lector-catalog/1"})
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read(), dict(response.headers)
        except urllib.error.HTTPError as error:
            if error.code in (401, 403, 404) and allow_missing:
                return None, {}
            if error.code == 429:
                reset = re.search(r"t=(\d+)", error.headers.get("ratelimit", "") or "")
                delay = int(reset.group(1)) + 1 if reset else 30
                print(f"  rate limited, waiting {delay}s", file=sys.stderr)
                time.sleep(delay)
                continue
            if error.code < 500:
                raise
            last_error = error
        except (OSError, http.client.HTTPException) as error:
            # URLError, timeouts, resets and truncated bodies are all worth another try.
            last_error = error
        print(f"  {last_error} fetching {url}; retrying in {backoff}s", file=sys.stderr)
        time.sleep(backoff)
    raise RuntimeError(f"giving up on {url}: {last_error}")


def fetch(url: str, *, api: bool, binary: bool = False, allow_missing: bool = False):
    cached = _cache_path(url)
    missing = cached.with_name(cached.name + ".missing")
    if cached.exists():
        data = cached.read_bytes()
        return data if binary else data.decode("utf-8")
    if missing.exists() and allow_missing:
        return None
    data, _ = _get(url, api=api, allow_missing=allow_missing)
    if data is None:
        missing.write_text("missing")
        return None
    cached.write_bytes(data)
    return data if binary else data.decode("utf-8")


def api_json(path: str):
    return json.loads(fetch(f"{HUB}/api/{path}", api=True))


def api_list(path: str) -> list:
    """Every page of a listing endpoint, following its `Link: rel="next"` cursor."""
    cached = _cache_path(f"{HUB}/api/{path}#all")
    if cached.exists():
        return json.loads(cached.read_text())
    results: list = []
    url: str | None = f"{HUB}/api/{path}"
    while url:
        body, headers = _get(url, api=True, allow_missing=False)
        results += json.loads(body)
        match = re.search(r"<([^>]+)>;\s*rel=\"next\"", headers.get("Link", ""))
        url = match.group(1) if match else None
    cached.write_text(json.dumps(results))
    return results


def repo_file(repo: str, revision: str, path: str, *, binary: bool = False, allow_missing: bool = True):
    return fetch(f"{HUB}/{repo}/resolve/{revision}/{urllib.parse.quote(path)}", api=False,
                 binary=binary, allow_missing=allow_missing)


# ---------------------------------------------------------------------------------------
# Languages.

_likely_scripts: dict[str, str] | None = None


def default_script(language: str) -> str | None:
    """The script a language is written in by default, from CLDR's likely subtags - the
    same data Foundation's `maximalIdentifier` uses at runtime."""
    global _likely_scripts
    if _likely_scripts is None:
        body = fetch("https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/"
                     "cldr-core/supplemental/likelySubtags.json", api=False)
        subtags = json.loads(body)["supplemental"]["likelySubtags"]
        _likely_scripts = {}
        for tag, maximal in subtags.items():
            if "-" not in tag and tag != "und":
                parts = maximal.split("-")
                if len(parts) > 1 and len(parts[1]) == 4:
                    _likely_scripts[tag] = parts[1]
    return _likely_scripts.get(language)


def language_key(code: str) -> str | None:
    """The app's key for an Opus language label: ISO 639-1 where one exists, else 639-3;
    a script suffix only where it differs from the language's default, except Chinese,
    which always carries one because both scripts are someone's default."""
    base, _, rest = code.partition("_")
    script = rest if len(rest) == 4 and rest[:1].isupper() else None
    base = INDIVIDUAL_TO_MACRO.get(base, base)
    if not re.fullmatch(r"[a-z]{2,3}", base):
        return None
    if len(base) == 3:
        entry = pycountry.languages.get(alpha_3=base)
        if entry is None:
            return None
        base = getattr(entry, "alpha_2", base)
    elif pycountry.languages.get(alpha_2=base) is None and base != "nb":
        return None
    if base == "zh":
        return f"zh-{script}" if script in ("Hans", "Hant") else None
    default = default_script(base)
    # Korean's default "Kore" is Hangul plus Hanja; plain Hangul is ordinary Korean.
    if script and script != default and not (default == "Kore" and script == "Hang"):
        return f"{base}-{script}"
    return base


def keys_for(codes: list[str], *, writing: bool = False) -> set[str]:
    keys = set()
    for code in codes:
        base = INDIVIDUAL_TO_MACRO.get(code.split("_")[0], code.split("_")[0])
        if base in ("zh", "zho") and "_" not in code:
            # Unscripted Chinese: read in either script, written in Simplified, which is
            # what the training data overwhelmingly is.
            keys |= {"zh-Hans"} if writing else {"zh-Hans", "zh-Hant"}
            continue
        key = language_key(code)
        if key:
            keys.add(key)
    return keys


# ---------------------------------------------------------------------------------------
# Model cards and exports.

def card_languages(model: str) -> tuple[list[str], list[str], bool, str | None, str | None]:
    """Source codes, target codes, whether a target token is required, and the card's
    names for the source and target groups when the model covers a family."""
    card = repo_file(f"Helsinki-NLP/{model}", "main", "README.md") or ""
    def listed(side: str) -> list[str]:
        for pattern in (rf"\*\s*{side} language\(s\):\s*(.+)", rf"\*\s*{side} languages:\s*(.+)"):
            match = re.search(pattern, card)
            if match:
                return [c for c in re.split(r"[\s,]+", match.group(1).strip()) if c]
        return []
    def group(side: str) -> str | None:
        match = re.search(rf"\*\s*{side} group:\s*(.+)", card)
        return match.group(1).strip() if match else None
    sources, targets = listed("source"), listed("target")
    name = model.removeprefix("opus-mt-").removeprefix("tc-big-").removeprefix("tc-base-")
    if not sources or not targets:
        parts = name.split("-")
        if len(parts) == 2:
            sources = sources or [parts[0]]
            targets = targets or [parts[1]]
    needs_token = "sentence initial language token is required" in card
    return sources, targets, needs_token, group("source"), group("target")


@dataclass
class Export:
    repo: str
    revision: str
    helsinki: str
    files: list[tuple[str, str, int, str]]  # remote path, local name, bytes, LFS sha256 or ""
    merged: bool

    @property
    def bytes(self) -> int:
        return sum(size for _, _, size, _ in self.files)


def export_files(listing: dict[str, int | None]) -> tuple[list[tuple[str, str]], bool] | None:
    """The files to fetch from an export, as (remote, local) pairs, and whether its decoder
    is the merged kind. The smallest quantised variant of each graph is preferred."""
    for prefix in ("onnx/", "", "int8/"):
        def first(*names: str) -> str | None:
            for name in names:
                if prefix + name in listing and listing[prefix + name]:
                    return prefix + name
            return None
        encoder = first("encoder_model_quantized.onnx", "encoder_model_int8.onnx",
                        "encoder_model.onnx" if prefix == "int8/" else "")
        if not encoder:
            continue
        tokenizer_prefix = prefix if (prefix + "vocab.json") in listing else ""
        if not all((tokenizer_prefix + f) in listing for f in ("source.spm", "vocab.json", "config.json")):
            return None
        support = [(tokenizer_prefix + f, f) for f in ("source.spm", "vocab.json", "config.json")]
        if (tokenizer_prefix + "target_vocab.json") in listing:
            support.append((tokenizer_prefix + "target_vocab.json", "target_vocab.json"))
        merged_options = [p for p in (prefix + "decoder_model_merged_quantized.onnx",
                                      prefix + "decoder_model_merged_int8.onnx") if p in listing]
        split_options = [(a, b) for a, b in (
            (prefix + "decoder_model_quantized.onnx", prefix + "decoder_with_past_model_quantized.onnx"),
            (prefix + "decoder_model_int8.onnx", prefix + "decoder_with_past_model_int8.onnx"),
            (prefix + "decoder_model.onnx", prefix + "decoder_with_past_model.onnx") if prefix == "int8/" else ("", ""),
        ) if a in listing and b in listing]
        merged = min(merged_options, key=lambda p: listing[p] or 1 << 62, default=None)
        split = min(split_options, key=lambda ab: (listing[ab[0]] or 0) + (listing[ab[1]] or 0), default=None)
        if merged and (not split or (listing[merged] or 0) <= (listing[split[0]] or 0) + (listing[split[1]] or 0)):
            return [(encoder, "encoder.onnx"), (merged, "decoder_merged.onnx")] + support, True
        if split:
            return [(encoder, "encoder.onnx"), (split[0], "decoder.onnx"),
                    (split[1], "decoder_with_past.onnx")] + support, False
        return None
    return None


def helsinki_name(repo: str, config: dict | None, helsinki: set[str]) -> str | None:
    name = (config or {}).get("_name_or_path", "")
    if name.startswith("Helsinki-NLP/") and name.split("/", 1)[1] in helsinki:
        return name.split("/", 1)[1]
    base = repo.split("/", 1)[1]
    base = re.sub(r"^onnx-", "", base)
    base = re.sub(r"(-onnx-int8|-onnx-quantized|-onnx|-ONNX)$", "", base)
    return base if base in helsinki else None


ARCHITECTURE_KEYS = ("d_model", "encoder_layers", "decoder_layers", "encoder_attention_heads",
                     "decoder_attention_heads", "vocab_size", "decoder_start_token_id",
                     "eos_token_id", "pad_token_id")


def matches_original(export: dict, tokenizer_prefix: str, model: str) -> bool:
    """Whether an export's tokenizer and architecture are the Helsinki model's own.

    Git blob ids (or LFS hashes) settle most files without downloading them; a vocabulary
    re-serialised by the exporter is compared by content instead."""
    original = api_json(f"models/Helsinki-NLP/{model}?blobs=true")
    ours_by_name = {s["rfilename"]: s for s in export.get("siblings", [])}
    theirs_by_name = {s["rfilename"]: s for s in original.get("siblings", [])}
    for name in ("source.spm", "vocab.json"):
        ours, theirs = ours_by_name.get(tokenizer_prefix + name), theirs_by_name.get(name)
        if not ours or not theirs:
            return False
        if ours.get("lfs") and theirs.get("lfs"):
            if ours["lfs"]["sha256"] != theirs["lfs"]["sha256"]:
                return False
            continue
        if not ours.get("lfs") and not theirs.get("lfs") and ours.get("blobId") == theirs.get("blobId"):
            continue
        ours_data = repo_file(export["id"], export["sha"], tokenizer_prefix + name, binary=True)
        theirs_data = repo_file(f"Helsinki-NLP/{model}", original["sha"], name, binary=True)
        if ours_data is None or theirs_data is None:
            return False
        if name == "vocab.json":
            if json.loads(ours_data) != json.loads(theirs_data):
                return False
        elif ours_data != theirs_data:
            return False
    ours_config = json.loads(repo_file(export["id"], export["sha"], tokenizer_prefix + "config.json") or "{}")
    theirs_config = json.loads(repo_file(f"Helsinki-NLP/{model}", original["sha"], "config.json") or "{}")
    return (ours_config.get("model_type") == "marian"
            and all(ours_config.get(k) == theirs_config.get(k) for k in ARCHITECTURE_KEYS))


@dataclass
class Entry:
    export: Export
    sources: set[str]
    targets: dict[str, str | None]
    kind: str
    source_group: str | None
    target_group: str | None


def target_tokens(export: Export, model: str, target_codes: list[str], needs_token: bool) -> dict[str, str | None]:
    if not needs_token:
        return {key: None for key in keys_for(target_codes, writing=True)}
    prefix = next((remote.rsplit("/", 1)[0] + "/" for remote, local, _, _ in export.files
                   if local == "vocab.json" and "/" in remote), "")
    vocabulary = json.loads(repo_file(export.repo, export.revision, prefix + "vocab.json") or "{}")
    tokens = [t for t in vocabulary if re.fullmatch(r">>[A-Za-z_]+<<", t)]
    by_key: dict[str, list[str]] = {}
    for token in tokens:
        code = token[2:-2]
        key = language_key(code)
        if key:
            by_key.setdefault(key, []).append(code)
    chosen: dict[str, str | None] = {}
    for key, codes in by_key.items():
        base = key.split("-")[0]
        def rank(code: str) -> tuple:
            language, _, rest = code.partition("_")
            # The macrolanguage itself, or its standard individual form, before a dialect;
            # then no suffix before a script or region suffix.
            preferred = {"ar": "arb", "fa": "pes", "zh-Hans": "cmn_Hans", "zh-Hant": "cmn_Hant",
                         "ms": "zsm_Latn", "sw": "swh", "ne": "npi"}.get(key)
            return (code != preferred, language_key(language) != base, rest != "", code)
        chosen[key] = f">>{sorted(codes, key=rank)[0]}<<"
    return chosen


def build() -> list[Entry]:
    helsinki = {m["id"].split("/", 1)[1]
                for m in api_list("models?author=Helsinki-NLP&search=opus-mt&limit=1000")}
    print(f"{len(helsinki)} Helsinki-NLP models", file=sys.stderr)

    exports: dict[str, Export] = {}
    for publisher in PUBLISHERS:
        listing = api_list(f"models?author={publisher}&search=opus-mt&limit=1000")
        accepted = 0
        for item in sorted(listing, key=lambda m: m["id"]):
            repo = item["id"]
            # Most exports are named after their model; only ask the Hub about the others,
            # and never about a model a more trusted account already provides.
            model = helsinki_name(repo, None, helsinki)
            if model is None:
                config = json.loads(repo_file(repo, "main", "config.json") or "{}")
                model = helsinki_name(repo, config, helsinki)
            if not model or model in SKIP_MODELS or model in exports:
                continue
            info = api_json(f"models/{repo}?blobs=true")
            if info.get("private") or info.get("gated") or info.get("disabled"):
                continue
            siblings = {s["rfilename"]: s for s in info.get("siblings", [])}
            sizes = {name: s.get("size") for name, s in siblings.items()}
            layout = export_files(sizes)
            if not layout:
                continue
            files, merged = layout
            export = Export(repo, info["sha"], model, [
                (r, l, sizes[r], (siblings[r].get("lfs") or {}).get("sha256", "")) for r, l in files
            ], merged)
            if export.bytes > MAX_MODEL_BYTES:
                continue
            config_path = next(remote for remote, local in files if local == "config.json")
            tokenizer_prefix = config_path.rsplit("/", 1)[0] + "/" if "/" in config_path else ""
            if not matches_original(info, tokenizer_prefix, model):
                print(f"  {repo}: does not match Helsinki-NLP/{model}, skipped", file=sys.stderr)
                continue
            exports[model] = export
            accepted += 1
        print(f"{publisher}: {accepted} models", file=sys.stderr)

    entries = []
    for model, export in sorted(exports.items()):
        source_codes, target_codes, needs_token, source_group, target_group = card_languages(model)
        sources = keys_for(source_codes)
        targets = target_tokens(export, model, target_codes, needs_token)
        if not sources or not targets:
            print(f"  {model}: no usable languages, skipped", file=sys.stderr)
            continue
        if len(targets) > 1 and not all(targets.values()):
            # Several targets and no token to choose between them: nothing to steer with.
            print(f"  {model}: several targets without language tokens, skipped", file=sys.stderr)
            continue
        base_languages = lambda keys: {k.split("-")[0] for k in keys}
        widest = max(len(base_languages(sources)), len(base_languages(targets)))
        if widest >= MULTILINGUAL_THRESHOLD:
            kind = "multilingual"
        elif len(base_languages(sources)) == 1 and len(base_languages(targets)) == 1:
            kind = "specific"
        else:
            kind = "group"
        entries.append(Entry(export, sources, targets, kind, source_group, target_group))
    return entries


# ---------------------------------------------------------------------------------------
# Output.

def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def render(entries: list[Entry]) -> str:
    languages = set()
    for entry in entries:
        languages |= entry.sources | set(entry.targets)
    total = sum(entry.export.bytes for entry in entries)
    stamp = datetime.date.today().isoformat()
    lines = [
        f"// Generated by Scripts/generate-opus-mt-catalog.py on {stamp}. Do not edit; rerun it.",
        f"// {len(entries)} models covering {len(languages)} languages; "
        f"{total / 1e9:.1f} GB if every one were downloaded.",
        "",
        "extension OpusMTCatalog {",
        "    static let models: [OpusMTModel] = [",
    ]
    for entry in entries:
        export = entry.export
        files = ",\n".join(
            f"                .init({swift_string(remote)}, {swift_string(local)}, {size}, {swift_string(sha)})"
            for remote, local, size, sha in export.files)
        targets = " ".join(f"{key}{'=' + token if token else ''}" for key, token in sorted(entry.targets.items()))
        lines += [
            "        OpusMTModel(",
            f"            name: {swift_string(export.helsinki)},",
            f"            repository: {swift_string(export.repo)},",
            f"            revision: {swift_string(export.revision)},",
            f"            kind: .{entry.kind},",
            "            files: [",
            files,
            "            ],",
            f"            sources: {swift_string(' '.join(sorted(entry.sources)))},",
            f"            targets: {swift_string(targets)},",
            f"            sourceGroup: {swift_string(entry.source_group) if entry.source_group else 'nil'},",
            f"            targetGroup: {swift_string(entry.target_group) if entry.target_group else 'nil'}",
            "        ),",
        ]
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def main() -> None:
    entries = build()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(render(entries), encoding="utf-8")
    languages = set()
    for entry in entries:
        languages |= entry.sources | set(entry.targets)
    kinds = {k: sum(1 for e in entries if e.kind == k) for k in ("specific", "group", "multilingual")}
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(entries)} models {kinds}, "
          f"{len(languages)} language keys", file=sys.stderr)


if __name__ == "__main__":
    main()
