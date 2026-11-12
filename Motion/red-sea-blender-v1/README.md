# Red Sea Blender graphics

This work changes the graphics and round difficulty for the existing Make a
Way game. Its three rounds use 10 travellers in 45 seconds, 15 in 30 seconds,
and 20 in 15 seconds. Dragging, dry-path validation, completion rules and other
games keep their existing models.

## Native source and runtime approach

Blender 4.5 LTS runs locally through its command-line executable and `bpy`
Python API. The source scenes contain meshes, armatures, lights and materials;
they can also be opened in Blender's normal editor.

- `red-sea-characters.blend`: Moses and traveller character source.
- `build_characters.py`: Moses character construction.
- `animate_moses.py`: keyed lift, sea strike and settling action; sprite export.
- `build_travellers.py`: three traveller models, keyed turning/walking and export.
- `environment/red_sea_environment.blend`: native sea, shore and light source.
- `environment/build_environment.py`: environment construction/render script.
- `environment/alignment.json`: projection aligned to the existing drop polygon.

The mobile runtime plays complete rendered characters and environment frames.
It does not run Blender or a real-time 3D renderer on the phone. Flutter still
handles gestures, path movement, timing, pause/resume and results. Every
character frame has a fixed foot anchor so walking and dragging stay aligned.

The 2.6-second introduction coordinates the staff strike with the water opening.
The closed sea has a gentle wave loop before the introduction, sharing the
first 24 cells of the opening atlas to avoid another large decoded image.
The open sea loops after that introduction. Traveller turning precedes its
walking loop. Reduced-motion mode uses fixed frames without changing gameplay
timing.

Blender's Ocean modifier supplies wind-driven swell and crest foam. Two moving
FFT samples are crossfaded into a seamless field. The open-water sequence uses
48 frames over two seconds, and the parting front travels from the gathering
shore toward the far bank. Its receding surface and exposed sides form one
liquid volume, avoiding internal refraction seams during the opening.

Character sizes follow their distance in the scene: Moses stands behind the
waiting adults and has a comparable body height. Child travellers are shorter
than the adults. Character scale does not change the existing drag hit targets.

The sea surface remains at one elevation during opening. The revealed seabed
sits below it, with a sand ramp connecting the gathering shore to the channel.
Opening moves water sideways; it does not increase the water's height.

Character actions are saved on the native armatures in the `.blend` file. Sea
geometry is animated by `build_environment.py` when exporting the sequences.

## Build and review

The render scripts emit source manifests with frame paths, durations, looping
and character anchors. `pack_runtime_assets.py` combines those manifests into
WebP sprite atlases and a versioned runtime manifest. It limits textures
to 4096 pixels per axis and the combined decoded images to 128 MiB. The exported
provenance records original frame hashes and atlas hashes.

Default packing writes review-only files. The `--runtime` flag explicitly writes
the atlases under the mobile app's existing `assets/images/games/` directory.
Only the exported atlases and manifest belong in the app bundle; MPFB source
code and editable Blender scenes stay outside it.

`Frontend/mobile/tool/render_red_sea_blender_preview.dart` loads the review
manifest and captures the actual game engine using one drag per traveller. It uses
local fixtures and submits no backend activity. Run it from `Frontend/mobile`:

```sh
flutter test --no-pub tool/render_red_sea_blender_preview.dart
```

`RED_SEA_BLENDER_MANIFEST` optionally selects another manifest. Captured frames
and metadata go into this directory's `review/` folder. `RED_SEA_REVIEW_COUNT`
selects 10 (default), 15, or 20 travellers and their corresponding round timer.

## Asset provenance

The anatomical base, deformation targets, built-in rig and eyes come from the
MakeHuman/MPFB asset collection, released under CC0. MPFB's separate tool source
code is GPLv3, and its license explicitly treats exported models and renderings
as output using the CC0 assets. Copies of the source and asset license texts are
preserved in `source-assets/mpfb2/`.

The fitted robe uses Mindfront's kimono asset, whose `.mhclo` header identifies
Mindfront (Sweden) as its author and its license as CC0. The low-poly eyes' header
also records their CC0 release. Native garments, staff, sandals, beard, poses,
water and lighting are authored in the accompanying scene scripts.

These are new game graphics, not a scanned or historically verified likeness
of Moses.
