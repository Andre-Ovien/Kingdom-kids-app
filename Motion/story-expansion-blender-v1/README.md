# Five Bible stories and ten extra picture puzzles

The frozen content source is `Backend/Core/apps/stories/catalogue_expansion_v1.py`.
The five original English retellings are 181–199 words, each with five paragraphs,
a summary, a theme, and a two-minute reading estimate. They cover the Lost Sheep,
Joseph and his colorful coat, the Good Samaritan, Jericho, and Ruth supporting
Naomi by gleaning. The Jericho retelling omits graphic conflict details.

The additive `stories/0009_additional_bible_stories` migration depends on
`stories/0008_recorded_word_timings` and the existing `games/0014_ark_traffic_routes`.
It creates five story rows and ten separate puzzle games with three levels each.
Every new puzzle uses the existing 4/6/9-piece Puzzle Quest engine. The original
eight stories, nine games, IDs, progress, Esther quiz, Daniel memory game and
original Puzzle Quest remain intact. Seed replay uses get-or-create and does not
overwrite an edited row. Reverse retains catalogue data to preserve progress.
No live migration has been applied as part of this authoring work.

`data/catalogue-review.json` holds the complete authored payload for review.
`data/stories/` holds exact narration inputs without opening a database.

## Cover contract

Every new cover is authored and rendered in Blender, with saved editable scenes
and the deterministic `source/build_covers.py` script. Human anatomy, fitted
garments and rigs reuse the accepted dark-skinned Red Sea CC0 MPFB source. New
environments, sheep, props and poses are native Blender geometry. All human
characters are dark-skinned. Animal colors are natural. No rejected Kai source,
image-generation service, stock illustration, baked title or story text is used.

Runtime files belong in **Frontend/mobile/assets/images/stories/**, using:

- `lost-sheep-blender-v1.webp`
- `joseph-colorful-coat-blender-v1.webp`
- `good-samaritan-blender-v1.webp`
- `walls-of-jericho-blender-v1.webp`
- `ruth-and-naomi-blender-v1.webp`

Each cover is square, intended at 1024 × 1024, with central subjects readable in
the existing story cards and the picture-puzzle board. Shared app mapping and
pubspec registration are handled by the coordinating agent. New puzzle games
reuse the five existing approved story covers for Esther, Noah, David, Red Sea
and Jonah, then the five new covers above.

The first Lost Sheep hero is reviewed before producing all five final covers.
The current source includes a kneeling shepherd beside the found lamb, a staff,
bright sunlight, rich meadow greens, clustered plants and a worn winding path.

## Original recorded narration pipeline

The existing approved synthetic references remain unchanged: Kai option 2
(`boy2`), Nia and Zuri. The five new StoryNarration options start as `processing`
until the validated local recordings are installed. No generic TTS voice is
introduced. On the 8 GB Mac, the coordinator reserves one heavy model/render
lane and clears generation before the following commands are run.

Export only the additive text, without reading or writing a database:

```sh
cd Backend
.venv/bin/python scripts/export_additional_story_inputs.py
```

This writes five exact inputs to both `media/character_narration/story_inputs`
(for verification) and `story_inputs/additional` (for a five-story generation
batch). Generate with the already downloaded 0.6B model and accepted references:

```sh
~/.cache/kingdom-kids-voices/.venv/bin/python scripts/generate_character_narration.py story --character accepted --story-dir media/character_narration/story_inputs/additional --model-dir ~/.cache/kingdom-kids-voices/models/models--mlx-community--Qwen3-TTS-12Hz-0.6B-Base-4bit/snapshots/0d6bb6fe33f92d47a507e23b9148940e8366ab5b
```

After generation exits, select the five new slugs when running the existing
`align_character_narration.py --write` and `verify_character_narration.py`
pipeline documented in Backend/README.md. Pass `--character kai --character nia
--character zuri` and repeat `--story` for each new slug. Use the downloaded
Whisper snapshot; no new service or model installation is needed. Alignment
uses measured cross-attention/DTW boundaries, and must cover the exact canonical
text. Do not invent or evenly distribute word timestamps. Store the new QA
reports separately so existing narration review reports remain intact.

Audio stays in the existing ignored `Backend/media/character_narration` tree.
The coordinator will explicitly clear a future migration/installer step.
Source, exact text, reference hashes and completed alignment are reviewable first.

## Editorial references

Original retellings were checked against the biblical passages, using the public
domain KJV text as the primary event source:

- [Lost Sheep, Luke 15:1–7](https://www.biblegateway.com/passage/?search=Luke+15%3A1-7&version=KJV)
- [Joseph, Genesis 37](https://www.biblegateway.com/passage/?search=Genesis+37&version=KJV)
- [Good Samaritan, Luke 10:25–37](https://www.biblegateway.com/passage/?search=Luke+10%3A25-37&version=KJV)
- [Jericho, Joshua 6](https://www.biblegateway.com/passage/?search=Joshua+6&version=KJV)
- [Ruth and Naomi, Ruth 1–2](https://www.biblegateway.com/passage/?search=Ruth+1-2&version=KJV)

CC0 base asset licensing and MPFB tool provenance remain documented in
`Motion/red-sea-blender-v1/README.md` and its preserved license files. This work
does not modify that accepted source.
