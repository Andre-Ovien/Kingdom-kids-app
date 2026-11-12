# Five-story narration batch

Only Good Samaritan, Joseph and His Colorful Coat, Lost Sheep, Ruth and Naomi,
and Walls of Jericho are generated. Kai uses the previously accepted option 2
(`boy2`); Nia and Zuri use their accepted reference WAVs. References and canonical
inputs are copied byte-for-byte into the new isolated output directory:
`Backend/media/character_narration_additional_v1/`.

The script validates every staged text and voice SHA256, title, avatar, review
status, and format before every phase. Existing narration is fingerprinted and
checked after packaging. Existing stories, voices, global manifests, dependencies,
and database rows are never changed by this batch.

From the repository root, preparation loads no MLX/model:

```sh
/Users/macbook/.cache/kingdom-kids-voices/.venv/bin/python Motion/story-expansion-blender-v1/narration/run_five_story_narration.py prepare
```

After the coordinating agent explicitly clears the heavy runtime lane:

```sh
/Users/macbook/.cache/kingdom-kids-voices/.venv/bin/python Motion/story-expansion-blender-v1/narration/run_five_story_narration.py all
```

Individual resumable phases are `generate`, `structural`, `align`, `asr`,
`asr-compatible`, and
`package`. Completed valid speech tracks are skipped, and alignment resumes only
missing/invalid measured cues. No automatic force regeneration occurs. Separate
processes release TTS before loading Whisper. All generation uses local cached
model snapshots with Hugging Face offline mode; no paid API or new voice design.

There are 969 canonical words per voice, 2,907 total spoken words, and 75 speech
paragraphs. The earlier 24 tracks measured 154.48 words/minute and 0.964 generation
seconds/audio second, suggesting about 19 minutes of new audio and 18 minutes of
speech synthesis. Allow approximately 25–35 minutes for synthesis, measured
alignment, and independent paragraph-wise ASR, depending on memory pressure.
TTS weights plus speech tokenizer occupy 1.59 GiB on disk; Whisper weights occupy
0.27 GiB. These are file sizes, not measured peak runtime memory.

`review/narration/preflight.json` contains the validated provenance. Phase logs,
timings, raw independent ASR differences, structural findings, measured alignment
diagnostics, and a final track inventory are written under that same review
directory. Whisper canonical cross-attention/DTW supplies the word timings;
strict UTF16 coverage checks forbid skipped story words or invented evenly
distributed timing. Raw ASR differences and alignment warnings remain available
for listening review, rather than being removed to create a passing result.

The final `Backend/media/character_narration_additional_v1/additional-manifest.json`
contains precisely 15 new tracks and no narrator-sample replacements. It is
installer-compatible after the canonical stories exist in the database. The batch
only prepares this manifest; installation remains the coordinating agent's task.
New recordings use accepted voices but still require listening review.

The observed run took 32 minutes for speech generation. One new Zuri/Joseph
MP3 reached this LAME encoder's minimum 47-sample final partial frame while the
WAV had one residual sample. Exactly 46 zero PCM samples (1.92ms) were appended
after the intact generated PCM, then the MP3 was re-encoded. The original files,
sample-prefix proof, and physical duration/checksum changes are preserved under
`review/narration/export-repairs/`. No speech was regenerated or changed.

The installed MLX Audio tokenizer wrapper looks up `<|nospeech|>`, while the
cached official English Whisper snapshot defines `<|nocaptions|>` (50361).
The missing lookup resolves to the unknown/end-of-text token (50256), causing
the decoder to suppress EOS and repeat text after physical clips end. Both
unadapted raw reports are preserved. The additional `asr-compatible` phase
uses a tokenizer adapter scoped to that one model instance, restores the actual
snapshot token, and records every raw transcript/difference in
`independent-asr-token-compat.json`. No installed package or shared script is
modified. Packaging requires that corrected prompt-free pass for all 75
paragraphs and retains any remaining recognition differences for review.
