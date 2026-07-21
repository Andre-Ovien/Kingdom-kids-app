#!/usr/bin/env python3
"""Generate local Kingdom Kids narrator audition clips with OpenAI TTS.

The script reads ``OPENAI_API_KEY`` from the process environment or
``Backend/.env``. It never prints or writes the key. Generated audition files
live under ``Backend/media/voice_auditions`` which is already ignored by Git.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


BACKEND_DIR = Path(__file__).resolve().parents[1]
DEFAULT_ENV_FILE = BACKEND_DIR / ".env"
DEFAULT_OUTPUT_DIR = BACKEND_DIR / "media" / "voice_auditions"
SPEECH_ENDPOINT = "https://api.openai.com/v1/audio/speech"
MODEL = "gpt-4o-mini-tts"

AUDITION_SCRIPT = (
    "Come closer, little explorer. Tonight, we’re sailing with Noah beneath "
    "a sky full of stars. When the thunder rumbles, take a slow breath—God "
    "is still with us. Look! A rainbow stretches across the clouds. Are you "
    "ready to turn the page and discover what happens next?"
)

SHARED_DIRECTION = (
    "This is a polished story narration for children, performed by a young "
    "adult—not a child. Use clear contemporary English with a subtle, natural "
    "West African warmth in the cadence while remaining globally intelligible. "
    "Pronounce Noah clearly. Move naturally from an intimate invitation, to "
    "controlled tension during the thunder, to sincere reassurance on ‘God is "
    "still with us,’ and finish with delighted curiosity. Never use baby talk, "
    "a squeaky pitch, a cartoon voice, an exaggerated accent, a sing-song "
    "rhythm, or theatrical overacting. "
)


@dataclass(frozen=True)
class Audition:
    character: str
    variant: str
    label: str
    voice: str
    instructions: str

    @property
    def filename(self) -> str:
        return f"{self.character}_{self.variant}_{self.voice}.mp3"


AUDITIONS = (
    Audition(
        character="kai",
        variant="a",
        label="Steady Adventurer",
        voice="cedar",
        instructions=SHARED_DIRECTION
        + (
            "Kai is a warm, courageous young man with a smooth lower-mid "
            "register. Sound grounded, friendly, and quietly brave—like a "
            "trusted older brother leading an adventure. Keep the pace near "
            "126 words per minute and let a restrained smile enter the final "
            "question. Never sound stern, booming, gravelly, or sleepy."
        ),
    ),
    Audition(
        character="kai",
        variant="b",
        label="Gentle Protector",
        voice="onyx",
        instructions=SHARED_DIRECTION
        + (
            "Kai is a calm young adult protector with a warm, rounded lower "
            "register. Give the storm genuine weight without becoming dark, "
            "then make the reassurance feel safe and certain. Keep the pace "
            "near 120 words per minute. Avoid an announcer voice, sternness, "
            "melodrama, or an elderly quality."
        ),
    ),
    Audition(
        character="kai",
        variant="c",
        label="Curious Big Brother",
        voice="ash",
        instructions=SHARED_DIRECTION
        + (
            "Kai is an adventurous young man with an open, bright lower-mid "
            "voice and easy confidence. Sound conversational and present, "
            "with more curiosity than heroics. Keep the pace near 132 words "
            "per minute while preserving calm, clean pauses. Avoid sounding "
            "teenage, sarcastic, breathy, or overly casual."
        ),
    ),
    Audition(
        character="nia",
        variant="a",
        label="Gentle Guide",
        voice="marin",
        instructions=SHARED_DIRECTION
        + (
            "Nia is a nurturing young woman with a warm mezzo voice and "
            "quiet confidence. She feels like a reassuring older sister, not "
            "a whispering bedtime stereotype. Keep the pace near 116 words "
            "per minute, with soft but precise consonants and emotionally "
            "honest reassurance. Avoid breathiness, fragility, or sadness."
        ),
    ),
    Audition(
        character="nia",
        variant="b",
        label="Calm Wisdom",
        voice="sage",
        instructions=SHARED_DIRECTION
        + (
            "Nia is a serene young adult woman with a grounded mid-to-lower "
            "mezzo register. Her calm comes from confidence and attentiveness, "
            "not slowness. Keep the pace near 112 words per minute, gently "
            "lifting the rainbow moment. Avoid whispering, an elderly sound, "
            "flat delivery, or excessive softness."
        ),
    ),
    Audition(
        character="nia",
        variant="c",
        label="Tender Wonder",
        voice="alloy",
        instructions=SHARED_DIRECTION
        + (
            "Nia is a warm young woman with a clear middle register, tender "
            "curiosity, and composed emotional range. Keep the pace near 122 "
            "words per minute. Make each image easy to picture while keeping "
            "the delivery natural and modern. Avoid a clinical, neutral, "
            "childlike, or overly polished commercial tone."
        ),
    ),
    Audition(
        character="zuri",
        variant="a",
        label="Joyful Spark",
        voice="coral",
        instructions=SHARED_DIRECTION
        + (
            "Zuri is a vibrant young woman with a bright but full-bodied mid "
            "register. Her joy is rhythmic, spontaneous, and controlled. Keep "
            "the pace near 136 words per minute, slow down briefly for the "
            "reassurance, then let the rainbow and final question sparkle. "
            "Avoid squealing, rushing, giggling, or cartoon energy."
        ),
    ),
    Audition(
        character="zuri",
        variant="b",
        label="Playful Explorer",
        voice="nova",
        instructions=SHARED_DIRECTION
        + (
            "Zuri is an energetic young adult explorer with an agile, warm "
            "middle register. Sound delighted by discovery and highly engaged "
            "with the listener, while staying articulate. Keep the pace near "
            "140 words per minute with intentional pauses around the storm and "
            "reassurance. Avoid a teen voice, frantic speed, or forced cheer."
        ),
    ),
    Audition(
        character="zuri",
        variant="c",
        label="Radiant Storyteller",
        voice="shimmer",
        instructions=SHARED_DIRECTION
        + (
            "Zuri is a radiant young woman with a warm, expressive mid "
            "register and playful emotional precision. Keep the pace near 132 "
            "words per minute. Give the stars and rainbow vivid wonder without "
            "losing the grounded reassurance in the middle. Avoid a high-pitch "
            "character voice, breathiness, musical cadence, or overacting."
        ),
    ),
)


def load_env_file(path: Path) -> None:
    """Load simple KEY=VALUE entries without overwriting process variables."""

    if not path.is_file():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or key in os.environ:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        os.environ[key] = value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Kai, Nia, and Zuri OpenAI TTS audition clips.",
    )
    parser.add_argument(
        "--character",
        choices=("all", "kai", "nia", "zuri"),
        default="all",
        help="Limit generation to one character (default: all).",
    )
    parser.add_argument(
        "--variant",
        choices=("all", "a", "b", "c"),
        default="all",
        help="Limit generation to one candidate variant (default: all).",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"Destination directory (default: {DEFAULT_OUTPUT_DIR}).",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Regenerate files that already exist.",
    )
    return parser.parse_args()


def selected_auditions(character: str, variant: str) -> tuple[Audition, ...]:
    return tuple(
        audition
        for audition in AUDITIONS
        if (character == "all" or audition.character == character)
        and (variant == "all" or audition.variant == variant)
    )


def request_speech(api_key: str, audition: Audition) -> bytes:
    payload = {
        "model": MODEL,
        "voice": audition.voice,
        "input": AUDITION_SCRIPT,
        "instructions": audition.instructions,
        "response_format": "mp3",
    }
    request = Request(
        SPEECH_ENDPOINT,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "KingdomKidsVoiceAuditions/1.0",
        },
        method="POST",
    )

    try:
        with urlopen(request, timeout=180) as response:
            audio = response.read()
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")[:1200]
        raise RuntimeError(f"OpenAI returned HTTP {exc.code}: {body}") from exc
    except URLError as exc:
        raise RuntimeError(f"Could not reach the OpenAI speech API: {exc.reason}") from exc

    if len(audio) < 1024:
        raise RuntimeError(
            f"OpenAI returned an unexpectedly small audio response ({len(audio)} bytes)."
        )
    return audio


def write_audio(path: Path, audio: bytes) -> None:
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_bytes(audio)
    temporary_path.replace(path)


def file_record(output_dir: Path, audition: Audition) -> dict[str, object]:
    path = output_dir / audition.filename
    audio = path.read_bytes()
    record = asdict(audition)
    record.update(
        {
            "file": audition.filename,
            "bytes": len(audio),
            "sha256": hashlib.sha256(audio).hexdigest(),
        }
    )
    return record


def write_manifest(output_dir: Path) -> Path:
    available = [
        audition for audition in AUDITIONS if (output_dir / audition.filename).is_file()
    ]
    manifest = {
        "generated_at": datetime.now(UTC).isoformat(),
        "model": MODEL,
        "disclosure_required": "Narration is AI-generated.",
        "audition_script": AUDITION_SCRIPT,
        "candidates": [file_record(output_dir, audition) for audition in available],
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return manifest_path


def main() -> int:
    args = parse_args()
    load_env_file(DEFAULT_ENV_FILE)
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        print(
            f"OPENAI_API_KEY is missing. Add it to {DEFAULT_ENV_FILE} or export it.",
            file=sys.stderr,
        )
        return 2

    auditions = selected_auditions(args.character, args.variant)
    output_dir = args.output_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Generating {len(auditions)} audition clip(s) with {MODEL}...")
    generated = 0
    skipped = 0
    started_at = time.monotonic()

    for index, audition in enumerate(auditions, start=1):
        output_path = output_dir / audition.filename
        display_name = audition.character.title()
        if output_path.exists() and not args.force:
            print(
                f"[{index}/{len(auditions)}] Skipping {display_name} "
                f"{audition.variant.upper()} — already exists"
            )
            skipped += 1
            continue

        print(
            f"[{index}/{len(auditions)}] Rendering {display_name} "
            f"{audition.variant.upper()} — {audition.label} ({audition.voice})"
        )
        try:
            audio = request_speech(api_key, audition)
            write_audio(output_path, audio)
        except RuntimeError as exc:
            print(f"Generation failed: {exc}", file=sys.stderr)
            return 1
        generated += 1
        print(f"  Saved {output_path.name} ({len(audio):,} bytes)")

    manifest_path = write_manifest(output_dir)
    elapsed = time.monotonic() - started_at
    print(
        f"Done: {generated} generated, {skipped} skipped in {elapsed:.1f}s. "
        f"Manifest: {manifest_path}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
