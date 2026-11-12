#!/usr/bin/env python3
"""Create an original, deterministic 20-second Kingdom Kids sound-design bed."""

from __future__ import annotations

import math
import wave
from pathlib import Path

import numpy as np

SAMPLE_RATE = 48_000
DURATION = 20.0
N = int(SAMPLE_RATE * DURATION)
TIME = np.arange(N, dtype=np.float64) / SAMPLE_RATE
LEFT = np.zeros(N, dtype=np.float64)
RIGHT = np.zeros(N, dtype=np.float64)
RNG = np.random.default_rng(24082026)


def pan_gains(pan: float) -> tuple[float, float]:
    angle = (pan + 1.0) * math.pi / 4.0
    return math.cos(angle), math.sin(angle)


def add(signal: np.ndarray, start: float, pan: float = 0.0, gain: float = 1.0) -> None:
    index = max(0, int(start * SAMPLE_RATE))
    end = min(N, index + len(signal))
    if end <= index:
        return
    lg, rg = pan_gains(pan)
    length = end - index
    LEFT[index:end] += signal[:length] * gain * lg
    RIGHT[index:end] += signal[:length] * gain * rg


def midi_hz(note: int) -> float:
    return 440.0 * 2.0 ** ((note - 69) / 12.0)


def smooth_envelope(length: int, attack: float, release: float) -> np.ndarray:
    env = np.ones(length, dtype=np.float64)
    a = min(length, int(attack * SAMPLE_RATE))
    r = min(length, int(release * SAMPLE_RATE))
    if a:
        env[:a] = np.sin(np.linspace(0, math.pi / 2, a, endpoint=True)) ** 2
    if r:
        env[-r:] *= np.cos(np.linspace(0, math.pi / 2, r, endpoint=True)) ** 2
    return env


def pad_note(note: int, seconds: float, phase: float = 0.0) -> np.ndarray:
    t = np.arange(int(seconds * SAMPLE_RATE), dtype=np.float64) / SAMPLE_RATE
    hz = midi_hz(note)
    detunes = (0.994, 1.0, 1.006)
    sig = sum(np.sin(2 * math.pi * hz * d * t + phase + i * 0.7) for i, d in enumerate(detunes)) / 3
    sig += 0.22 * np.sin(2 * math.pi * hz * 2 * t + phase * 0.5)
    sig += 0.08 * np.sin(2 * math.pi * hz * 3 * t)
    return np.tanh(sig * 0.9) * smooth_envelope(len(t), 0.8, 1.15)


def bell(note: int, seconds: float = 2.2) -> np.ndarray:
    t = np.arange(int(seconds * SAMPLE_RATE), dtype=np.float64) / SAMPLE_RATE
    hz = midi_hz(note)
    partials = ((1.0, 1.0), (2.01, 0.43), (3.98, 0.18), (6.07, 0.08))
    sig = np.zeros_like(t)
    for index, (ratio, amp) in enumerate(partials):
        sig += amp * np.sin(2 * math.pi * hz * ratio * t + index * 0.35) * np.exp(-t * (1.6 + index * 0.65))
    return sig * smooth_envelope(len(t), 0.006, 0.5)


def felt_note(note: int, seconds: float = 1.2) -> np.ndarray:
    t = np.arange(int(seconds * SAMPLE_RATE), dtype=np.float64) / SAMPLE_RATE
    hz = midi_hz(note)
    sig = np.sin(2 * math.pi * hz * t) + 0.32 * np.sin(2 * math.pi * hz * 2.003 * t)
    sig += 0.09 * np.sin(2 * math.pi * hz * 4.01 * t)
    return np.tanh(sig * 0.85) * np.exp(-t * 2.9) * smooth_envelope(len(t), 0.015, 0.28)


def whoosh(seconds: float = 1.6, direction: float = -1.0) -> np.ndarray:
    length = int(seconds * SAMPLE_RATE)
    noise = RNG.normal(0, 1, length)
    # A soft moving-average filter keeps the air pass tactile rather than harsh.
    kernel = np.hanning(95)
    kernel /= kernel.sum()
    filtered = np.convolve(noise, kernel, mode='same')
    x = np.linspace(0, 1, length)
    env = np.sin(math.pi * x) ** 2.2
    air = filtered * env * (0.7 + 0.3 * np.sin(2 * math.pi * (3.5 + direction) * x))
    return air


def soft_hit(seconds: float = 1.0) -> np.ndarray:
    t = np.arange(int(seconds * SAMPLE_RATE), dtype=np.float64) / SAMPLE_RATE
    low = np.sin(2 * math.pi * (76 - 28 * t) * t) * np.exp(-t * 7.0)
    dust = RNG.normal(0, 1, len(t)) * np.exp(-t * 14.0)
    dust = np.convolve(dust, np.ones(25) / 25, mode='same')
    return (low * 0.8 + dust * 0.3) * smooth_envelope(len(t), 0.005, 0.22)


# Air and high shimmer throughout.
air = RNG.normal(0, 1, N)
air = np.convolve(air, np.ones(420) / 420, mode='same')
air_env = 0.5 + 0.5 * np.sin(np.linspace(0, math.pi, N))
LEFT += air * air_env * 0.048
RIGHT += np.roll(air, 810) * air_env * 0.045
LEFT += 0.006 * np.sin(2 * math.pi * 7140 * TIME + 0.3 * np.sin(2 * math.pi * 0.09 * TIME))
RIGHT += 0.006 * np.sin(2 * math.pi * 7210 * TIME + 0.2 * np.sin(2 * math.pi * 0.08 * TIME + 1.0))

# Eight warm 2.5-second harmonic chapters at 96 BPM.
chords = [
    (48, 55, 59, 64),  # Cmaj7
    (45, 52, 57, 60),  # Am
    (41, 48, 53, 57),  # Fmaj7
    (43, 50, 55, 59),  # G
    (48, 55, 60, 64),
    (45, 52, 57, 64),
    (41, 48, 55, 60),
    (48, 55, 59, 64),
]
for bar, chord in enumerate(chords):
    start = bar * 2.5
    for voice, note in enumerate(chord):
        signal = pad_note(note, 3.25, phase=voice * 0.4 + bar * 0.15)
        add(signal, start - 0.18, pan=(-0.48 + voice * 0.32), gain=0.052 if voice < 2 else 0.038)

# Story, play and together motifs.
motif = [(0.7, 72), (1.2, 76), (1.7, 79), (2.25, 83),
         (3.0, 76), (3.45, 79), (4.0, 84),
         (5.5, 72), (5.85, 76), (6.2, 79), (6.7, 84),
         (8.0, 67), (8.35, 72), (8.7, 76), (9.2, 79),
         (10.4, 72), (10.8, 76), (11.25, 79)]
for index, (when, note) in enumerate(motif):
    add(felt_note(note), when, pan=-0.35 + (index % 4) * 0.23, gain=0.075)

# Chapter punctuation.
for when, pan in ((2.5, -0.35), (5.0, 0.35), (7.5, 0.0), (10.0, -0.12), (12.5, 0.18), (15.0, 0.0)):
    add(soft_hit(), when, pan=pan, gain=0.12)

# Five moving wing passes for the dove flock.
for index, when in enumerate((12.63, 12.95, 13.3, 13.68, 14.03)):
    add(whoosh(1.8, -1), when, pan=0.78 - index * 0.28, gain=0.32 - index * 0.018)

# Transition lift and final brand resolution.
lift_len = int(2.5 * SAMPLE_RATE)
lift_t = np.arange(lift_len) / SAMPLE_RATE
lift_noise = RNG.normal(0, 1, lift_len)
lift_noise = np.convolve(lift_noise, np.ones(135) / 135, mode='same')
lift = lift_noise * np.linspace(0, 1, lift_len) ** 2 * np.linspace(1, 0.55, lift_len)
add(lift, 13.8, pan=0.0, gain=0.15)

for i, note in enumerate((72, 76, 79, 83, 88)):
    add(bell(note, 3.1), 15.1 + i * 0.15, pan=-0.48 + i * 0.24, gain=0.12 if i < 4 else 0.17)
for i, note in enumerate((60, 67, 71, 76)):
    add(bell(note, 3.8), 17.0 + i * 0.09, pan=-0.35 + i * 0.24, gain=0.095)

# Master fade, gentle bus saturation and 24-bit PCM export.
master_fade = np.ones(N)
master_fade[: int(0.4 * SAMPLE_RATE)] = np.linspace(0, 1, int(0.4 * SAMPLE_RATE)) ** 2
master_fade[-int(1.35 * SAMPLE_RATE):] = np.linspace(1, 0, int(1.35 * SAMPLE_RATE)) ** 1.35
stereo = np.stack([LEFT, RIGHT], axis=1) * master_fade[:, None]
stereo = np.tanh(stereo * 1.35)
peak = np.max(np.abs(stereo))
if peak > 0:
    stereo *= 0.82 / peak

pcm = np.clip(stereo * 8_388_607, -8_388_608, 8_388_607).astype(np.int32)
packed = (pcm.reshape(-1)[:, None] >> np.array([0, 8, 16], dtype=np.int32)) & 0xFF
audio_bytes = packed.astype(np.uint8).tobytes()

output = Path(__file__).resolve().parents[1] / 'public' / 'audio' / 'kingdom-kids-score.wav'
output.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(output), 'wb') as wav:
    wav.setnchannels(2)
    wav.setsampwidth(3)
    wav.setframerate(SAMPLE_RATE)
    wav.writeframes(audio_bytes)

print(output)
