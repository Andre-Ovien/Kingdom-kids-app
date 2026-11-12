#!/usr/bin/env python3
"""Reproduce Kingdom Kids' original procedural app music and interface sounds.

Requires Python 3 and NumPy. Run from any directory:
    python3 Frontend/mobile/tool/generate_app_sound_pack.py

All musical material is composed below. Instruments are synthesized from damped
resonators and generated strike noise; there are no recordings, external clips,
voices, or copied melodies. This provenance statement does not assign a license
or waive the project's ownership rights.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import wave

import numpy as np


SAMPLE_RATE = 44_100
SEED = 10_102_026
MOBILE_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = MOBILE_ROOT / "assets" / "audio" / "app"
DEFAULT_QA = Path(__file__).with_name("app_sound_pack_provenance.txt")


def db_to_gain(db: float) -> float:
    return 10.0 ** (db / 20.0)


def midi_frequency(note: float) -> float:
    return 440.0 * 2.0 ** ((note - 69.0) / 12.0)


def rounded_attack(t: np.ndarray, seconds: float) -> np.ndarray:
    # A zero-slope onset prevents the audible click of an instant sine start.
    phase = np.minimum(t / seconds, 1.0)
    return 0.5 - 0.5 * np.cos(np.pi * phase)


def strike_noise(rng: np.random.Generator, length: int, seconds: float) -> np.ndarray:
    t = np.arange(length, dtype=np.float64) / SAMPLE_RATE
    noise = rng.standard_normal(length)
    # Generated, very short, low-pass strike texture; no sustained noise bed.
    kernel = np.hanning(21)
    kernel /= kernel.sum()
    noise = np.convolve(noise, kernel, mode="same")
    return noise * rounded_attack(t, 0.0006) * np.exp(-t / seconds)


def instrument(
    kind: str,
    note: float,
    duration: float,
    rng: np.random.Generator,
    velocity: float = 1.0,
) -> np.ndarray:
    count = round(duration * SAMPLE_RATE)
    t = np.arange(count, dtype=np.float64) / SAMPLE_RATE
    freq = midi_frequency(note)
    y = np.zeros(count, dtype=np.float64)

    if kind == "marimba":
        # Warm struck wooden bars: short upper inharmonic modes, rounded body.
        modes = ((1.0, 1.0, 0.64), (2.76, 0.20, 0.20),
                 (5.40, 0.065, 0.085), (8.93, 0.017, 0.045))
        attack = 0.0034
        texture = 0.038 * strike_noise(rng, count, 0.005)
    elif kind == "celesta":
        # A softer music-box-like tine, with a tiny detuned beating companion.
        modes = ((1.0, 0.80, 0.82), (2.0, 0.28, 0.48),
                 (2.98, 0.12, 0.25), (4.03, 0.055, 0.14),
                 (5.18, 0.017, 0.085), (6.94, 0.007, 0.055))
        attack = 0.0045
        texture = 0.009 * strike_noise(rng, count, 0.003)
    elif kind == "pluck":
        # Plucked strings: lightly detuned harmonic resonances and fret/body tap.
        modes = tuple((float(h), 0.70 / h ** 1.65, 0.52 / h ** 0.35)
                      for h in range(1, 13))
        attack = 0.0030
        texture = 0.021 * strike_noise(rng, count, 0.006)
    elif kind == "bass":
        modes = ((1.0, 0.74, 0.82), (2.0, 0.15, 0.38),
                 (3.0, 0.028, 0.17), (4.0, 0.009, 0.09))
        attack = 0.011
        texture = np.zeros(count)
    elif kind == "wood":
        modes = ((1.0, 0.44, 0.015), (1.47, 0.25, 0.010),
                 (2.28, 0.15, 0.006), (3.61, 0.055, 0.004))
        attack = 0.0018
        texture = 0.14 * strike_noise(rng, count, 0.003)
    else:
        raise ValueError(f"Unknown instrument: {kind}")

    # A very small settling pitch after a strike makes the transient less rigid.
    settling = 0.00022 * freq * (1.0 - np.exp(-t / 0.025))
    for index, (ratio, amplitude, decay) in enumerate(modes):
        if freq * ratio >= SAMPLE_RATE * 0.44:
            continue
        phase = rng.uniform(-0.025, 0.025)
        envelope = np.exp(-t / decay)
        oscillation = np.sin(2.0 * np.pi * (freq * ratio * t + settling) + phase)
        if index == 0 and kind in ("celesta", "pluck"):
            oscillation = 0.94 * oscillation + 0.06 * np.sin(
                2.0 * np.pi * (freq * ratio * 1.0011 * t + settling) + phase
            )
        y += amplitude * envelope * oscillation

    y = (y + texture) * rounded_attack(t, attack) * velocity
    # End even the quiet residual tail smoothly, independently of note length.
    end_count = min(count, round(0.065 * SAMPLE_RATE))
    y[-end_count:] *= 0.5 + 0.5 * np.cos(np.linspace(0.0, np.pi, end_count))
    return y


def add_note(
    target: np.ndarray,
    kind: str,
    note: float,
    at: float,
    length: float,
    gain: float,
    pan: float,
    rng: np.random.Generator,
    circular: bool = False,
) -> None:
    sound = instrument(kind, note, length, rng, velocity=gain)
    # Equal-power panning, held modestly within the stereo field for phone audio.
    angle = (np.clip(pan, -1.0, 1.0) + 1.0) * np.pi / 4.0
    stereo = sound[:, None] * np.array([math.cos(angle), math.sin(angle)])
    start = round(at * SAMPLE_RATE)
    if circular:
        # All releases wrap into the next cycle rather than stopping at its edge.
        positions = (start + np.arange(len(sound))) % len(target)
        np.add.at(target, positions, stereo)
    else:
        source_start = max(-start, 0)
        destination_start = max(start, 0)
        count = min(len(sound) - source_start, len(target) - destination_start)
        if count > 0:
            target[destination_start:destination_start + count] += stereo[
                source_start:source_start + count
            ]


def add_room(dry: np.ndarray, circular: bool, amount: float = 0.23) -> np.ndarray:
    """A sparse, warm room response. Circular delay preserves the theme seam."""
    wet = np.zeros_like(dry)
    taps = ((0.041, 0.30), (0.067, 0.24), (0.103, 0.18),
            (0.139, 0.135), (0.181, 0.105), (0.233, 0.08),
            (0.301, 0.057), (0.383, 0.035), (0.479, 0.02))
    # Slightly different left/right arrival and cross-feed avoid a hard echo.
    for index, (seconds, gain) in enumerate(taps):
        for channel in (0, 1):
            delay = round((seconds + channel * 0.0037 + (index % 2) * 0.0019)
                          * SAMPLE_RATE)
            source_channel = channel if index % 3 else 1 - channel
            if circular:
                wet[:, channel] += gain * np.roll(dry[:, source_channel], delay)
            elif delay < len(dry):
                wet[delay:, channel] += gain * dry[:-delay, source_channel]
    return dry + amount * wet


def finish(
    samples: np.ndarray,
    target_rms_db: float,
    peak_ceiling_db: float,
    circular: bool = False,
) -> np.ndarray:
    samples = samples - samples.mean(axis=0, keepdims=True)
    if not circular:
        attack_count = round(0.0015 * SAMPLE_RATE)
        release_count = min(round(0.13 * SAMPLE_RATE), len(samples) // 3)
        boundary_window = np.ones(len(samples))
        boundary_window[:attack_count] = rounded_attack(
            np.arange(attack_count) / SAMPLE_RATE, attack_count / SAMPLE_RATE
        )
        boundary_window[-release_count:] = (
            0.5 + 0.5 * np.cos(np.linspace(0.0, np.pi, release_count))
        )
        samples *= boundary_window[:, None]
        # Fading a mean-zero short strike can introduce a tiny DC bias. Remove
        # it through the same window, preserving silent first/last cue samples.
        samples -= (samples.mean(axis=0, keepdims=True)
                    / boundary_window.mean()) * boundary_window[:, None]
    rms = float(np.sqrt(np.mean(samples ** 2)))
    peak = float(np.max(np.abs(samples)))
    gain = min(db_to_gain(target_rms_db) / max(rms, 1e-12),
               db_to_gain(peak_ceiling_db) / max(peak, 1e-12))
    return samples * gain


def compose_theme() -> np.ndarray:
    rng = np.random.default_rng(SEED)
    beat = 0.6  # 100 BPM, 12 bars of 4 beats: one 28.8-second cycle.
    result = np.zeros((round(48 * beat * SAMPLE_RATE), 2), dtype=np.float64)
    # D6 / G6 / Bm7 / Aadd9: quiet, spacious accompaniment, never an alarm cadence.
    chords = ((50, (62, 66, 69, 71)), (43, (59, 62, 67, 69)),
              (47, (59, 62, 66, 69)), (45, (61, 64, 69, 71)))
    melody = (
        ((0.00, 74), (0.75, 69), (1.50, 78), (2.50, 76), (3.25, 74)),
        ((0.25, 71), (1.00, 74), (2.25, 69), (3.00, 66)),
        ((0.00, 76), (0.75, 78), (1.50, 81), (2.75, 78), (3.50, 76)),
        ((0.00, 73), (0.75, 69), (1.50, 71), (2.50, 76), (3.25, 69)),
        ((0.00, 74), (1.00, 78), (1.75, 76), (2.50, 69), (3.50, 71)),
        ((0.25, 74), (1.00, 71), (2.00, 79), (2.75, 78), (3.50, 74)),
        ((0.00, 78), (1.00, 81), (2.00, 78), (3.25, 76)),
        ((0.00, 76), (0.75, 73), (1.50, 71), (2.75, 69)),
        ((0.25, 74), (1.00, 76), (1.75, 78), (2.75, 81)),
        ((0.00, 79), (1.25, 78), (2.00, 74), (3.00, 71)),
        ((0.00, 78), (0.75, 76), (1.50, 74), (2.75, 71)),
        ((0.00, 73), (1.00, 76), (2.25, 69), (3.50, 66)),
    )
    for bar in range(12):
        bass, harmony = chords[bar % len(chords)]
        origin = bar * 4 * beat
        add_note(result, "bass", bass, origin, 2.5, 0.12, -0.03, rng, True)
        add_note(result, "bass", bass + 12, origin + 2.5 * beat,
                 1.3, 0.055, 0.03, rng, True)
        # Off-beat string figures make a small, gentle forward sway.
        for tick, chord_index in ((0.0, 0), (0.75, 2), (1.5, 1),
                                  (2.25, 3), (3.0, 2), (3.5, 1)):
            jitter = rng.uniform(-0.005, 0.005)
            velocity = 0.042 * rng.uniform(0.82, 1.09)
            add_note(result, "pluck", harmony[chord_index], origin + tick * beat
                     + jitter, 1.8, velocity, -0.28, rng, True)
        for index, (offset, note) in enumerate(melody[bar]):
            jitter = rng.uniform(-0.003, 0.003) if offset else 0.0
            velocity = 0.10 * rng.uniform(0.86, 1.12)
            if index == 0:
                velocity *= 1.05
            add_note(result, "marimba", note, origin + offset * beat + jitter,
                     2.1, velocity, 0.17, rng, True)
        if bar in (0, 4, 8):
            add_note(result, "celesta", 86, origin + 0.06, 2.4,
                     0.018, 0.36, rng, True)
            add_note(result, "celesta", 81, origin + 2.75 * beat, 2.0,
                     0.014, -0.30, rng, True)
    result = finish(add_room(result, True, 0.29), -24.0, -9.0, True)
    # Begin at a naturally quiet stereo zero crossing within the first 10 ms.
    # Rotation preserves the cycle and every tail; it also avoids a startup pop
    # when an audition player begins from silence rather than already looping.
    start = int(np.argmin(np.max(np.abs(result[:round(0.010 * SAMPLE_RATE)]), axis=1)))
    return np.roll(result, -start, axis=0)


def compose_cue(name: str) -> np.ndarray:
    settings = {
        "splash": (1.25, -21.0, -7.5),
        "streak": (1.60, -20.0, -7.0),
        "level_up": (1.85, -19.5, -6.8),
        "tap": (0.08, -26.0, -13.0),
        "select": (0.18, -23.0, -10.0),
        "success": (0.64, -21.0, -8.0),
    }
    duration, rms_db, peak_db = settings[name]
    # Explicit independent seeds preserve files when another cue changes.
    seeds = {"splash": 103, "streak": 211, "level_up": 307,
             "tap": 401, "select": 503, "success": 601}
    rng = np.random.default_rng(SEED + seeds[name])
    result = np.zeros((round(duration * SAMPLE_RATE), 2))

    if name == "tap":
        add_note(result, "wood", 71, 0.0, 0.08, 0.23, 0.0, rng)
        return finish(result, rms_db, peak_db)
    if name == "select":
        add_note(result, "pluck", 74, 0.0, 0.18, 0.28, 0.0, rng)
        add_note(result, "marimba", 86, 0.008, 0.16, 0.035, 0.12, rng)
        return finish(add_room(result, False, 0.10), rms_db, peak_db)
    if name == "splash":
        notes = ((0.025, 74), (0.155, 78), (0.290, 81), (0.445, 86))
        for index, (at, note) in enumerate(notes):
            add_note(result, "celesta", note, at, duration - at,
                     0.13 + index * 0.007, (index - 1.5) * 0.16, rng)
        add_note(result, "marimba", 62, 0.025, 1.20, 0.095, 0.0, rng)
        add_note(result, "pluck", 69, 0.445, 0.8, 0.075, -0.15, rng)
    elif name == "streak":
        notes = ((0.02, 69), (0.175, 74), (0.335, 78), (0.525, 81))
        for index, (at, note) in enumerate(notes):
            add_note(result, "marimba", note, at, duration - at,
                     0.17, -0.14 + index * 0.09, rng)
            add_note(result, "celesta", note + 12, at + 0.014,
                     duration - at - 0.014, 0.039, 0.17, rng)
        for note in (62, 66, 71):
            add_note(result, "pluck", note, 0.53, 1.05, 0.075, -0.15, rng)
    elif name == "level_up":
        notes = ((0.025, 74), (0.155, 78), (0.285, 81),
                 (0.44, 83), (0.645, 86))
        for index, (at, note) in enumerate(notes):
            add_note(result, "marimba", note, at, duration - at,
                     0.155, -0.23 + index * 0.10, rng)
            add_note(result, "celesta", note + 12, at + 0.017,
                     duration - at - 0.017, 0.033, 0.15, rng)
        for note in (62, 66, 69):
            add_note(result, "pluck", note, 0.65, 1.20, 0.075, -0.16, rng)
        add_note(result, "celesta", 90, 0.69, 1.16, 0.041, 0.29, rng)
    elif name == "success":
        add_note(result, "marimba", 78, 0.009, 0.62, 0.21, -0.10, rng)
        add_note(result, "marimba", 81, 0.125, 0.515, 0.21, 0.11, rng)
        add_note(result, "pluck", 62, 0.125, 0.515, 0.085, -0.17, rng)
        add_note(result, "celesta", 86, 0.137, 0.5, 0.045, 0.17, rng)
    return finish(add_room(result, False, 0.24), rms_db, peak_db)


def write_wav(path: Path, audio: np.ndarray) -> np.ndarray:
    # Saturation is prohibited; headroom must be created in finish(), never here.
    if not np.isfinite(audio).all() or np.max(np.abs(audio)) >= 1.0:
        raise ValueError(f"Non-finite or clipped audio for {path.name}")
    pcm = np.rint(audio * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm.tobytes())
    return pcm.astype(np.float64) / 32768.0


def metrics(path: Path, audio: np.ndarray, loop: bool = False) -> dict:
    peak = float(np.max(np.abs(audio)))
    rms = float(np.sqrt(np.mean(audio ** 2)))
    result = {
        "file": path.name,
        "duration_seconds": round(len(audio) / SAMPLE_RATE, 5),
        "sample_rate_hz": SAMPLE_RATE,
        "channels": 2,
        "pcm_bits": 16,
        "bytes": path.stat().st_size,
        "peak_dbfs": round(20.0 * math.log10(max(peak, 1e-12)), 3),
        "rms_dbfs": round(20.0 * math.log10(max(rms, 1e-12)), 3),
        "channel_dc": [round(float(x), 9) for x in audio.mean(axis=0)],
        "clipped_samples": int(np.count_nonzero(np.abs(audio) >= 0.9999)),
        "first_frame": [round(float(x), 8) for x in audio[0]],
        "last_frame": [round(float(x), 8) for x in audio[-1]],
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
    if loop:
        steps = np.diff(audio, axis=0)
        edge_step = np.abs(audio[0] - audio[-1])
        ordinary_step_limit = np.quantile(np.abs(steps), 0.99, axis=0)
        seam_curvature = np.abs(audio[0] - 2.0 * audio[-1] + audio[-2])
        result.update({
            "loop_edge_step": [round(float(x), 9) for x in edge_step],
            "p99_internal_step": [round(float(x), 9)
                                  for x in ordinary_step_limit],
            "rms_internal_step": [round(float(x), 9)
                                  for x in np.sqrt(np.mean(steps ** 2, axis=0))],
            "peak_internal_step": [round(float(x), 9)
                                   for x in np.max(np.abs(steps), axis=0)],
            "loop_seam_curvature": [round(float(x), 9) for x in seam_curvature],
        })
        # A continuous waveform need not have equal first/last sample values.
        # Its wrap step should sit inside normal waveform movement, not jump.
        if np.any(edge_step > ordinary_step_limit):
            raise ValueError("Loop edge exceeds ordinary waveform sample movement")
    else:
        if np.max(np.abs(audio[[0, -1]])) > 1.0 / 32768.0:
            raise ValueError(f"Non-zero cue boundary in {path.name}")
    if result["clipped_samples"] != 0:
        raise ValueError(f"Clipped samples in {path.name}")
    if np.max(np.abs(audio.mean(axis=0))) > 1e-6:
        raise ValueError(f"Unexpected DC offset in {path.name}")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--qa-note", type=Path, default=DEFAULT_QA)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = []
    for name in ("app_theme", "splash", "streak", "level_up", "tap", "select", "success"):
        audio = compose_theme() if name == "app_theme" else compose_cue(name)
        path = args.output / f"{name}.wav"
        quantized = write_wav(path, audio)
        report.append(metrics(path, quantized, loop=name == "app_theme"))

    note = """KINGDOM KIDS ORIGINAL APP SOUND PACK

Provenance
All seven WAV files were procedurally synthesized from this project's generator.
The generator composes its own notes, arrangements, instrument resonances and
short strike textures. No third-party samples, downloaded media, voices, paid
services or existing-song melodies were used. This statement records provenance;
it does not grant a license, make a CC0 dedication or waive project ownership.

Character
app_theme: 28.8-second, 100 BPM original D-major instrumental; warm wooden melody,
quiet plucked-string accompaniment, low rounded bass, occasional celesta sparkle.
splash: welcoming rising four-note celesta arrival over a warm lower wooden note.
streak: cheerful ascending wooden chimes with a soft, harmonious plucked reward.
level_up: a related, brighter five-note celebration, gently wider in stereo.
tap: small woody tick with rounded transients; intentionally quiet and very short.
select: short warm string pluck with a tiny upper wooden response.
success: compact two-note positive resolution, a quiet lower chord and bright tail.

Playback guidance
Theme is intended as a quiet bed, typically around 0.2-0.35 player volume; avoid
stacking multiple instances. The default WAV mix is intentionally below full scale.
Pause the theme for story narration, gameplay with dedicated audio and background
app state. UI cues should not repeat on rebuild or play when sound is disabled.
This note describes asset intent; app lifecycle, audio focus, mute and route
behavior must be verified by the playback integration.

Loop construction
The theme is exactly 48 quarter-note beats. Every note release and room-response
delay wraps circularly across the boundary; there is no gap or artificial full-mix
fade at the seam. No loop-start sound is repeated as a separate effect. Numeric
edge continuity is measured on the final quantized PCM, not only the float mix.
The cycle starts at a naturally quiet stereo crossing within 10 milliseconds of
the bar boundary, keeping the first preview frame near silence without fading
out the loop or cutting off preceding note releases.

Verification limits
Format, duration, DC, peaks, RMS, clipping and boundary continuity were checked
numerically. These checks do not establish subjective musical quality or loudness
comfort on a specific phone; review the previews on the actual device before
finalizing playback volume. The creator did not claim an audible listening review.
SHA-256 values allow a deterministic rerun to be compared without guessing.

PCM measurements
"""
    note += json.dumps(report, indent=2) + "\n"
    note += f"\nTotal asset bytes: {sum(item['bytes'] for item in report)}\n"
    args.qa_note.parent.mkdir(parents=True, exist_ok=True)
    args.qa_note.write_text(note)
    print(json.dumps({"files": report, "qa_note": str(args.qa_note.resolve())}, indent=2))


if __name__ == "__main__":
    main()
