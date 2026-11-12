# David native gameplay review

The review clip contains 500 actual Flutter-rendered phone frames at 60 fps (390 × 844), captured from the real GamePlayScreen through a stone pull-and-release gesture. It shows the original Goliath illustration with an articulated fall with constrained hip movement, painted army background, physical landing hold and the app’s existing completion screen. The selected profile and successful save are in-memory fixtures; this recording performs no network writes.

The audio uses the app’s existing bundled ambience, launch, impact and landing WAV files, mixed at the measured native painter cue triggers in articulated-fall-v4-timings.json. The visual harness disables the native audio plugin; this is not a recording of device speakers. Ambience ends when the real completion screen replaces the battlefield.

- Gameplay clip: david-articulated-fall-review-v4.mp4
- Actual completion frame: articulated-fall-v4-completion.png
- Live sequence contact sheet: articulated-fall-v4-contact-sheet.jpg
- Fast native renderer probes for all three bounds and both input directions: articulated-fall-v4-target-160-180.jpg, articulated-fall-v4-target-225-145.jpg, articulated-fall-v4-target-148-92.jpg
- Exact image generation edit prompts, references, saved paths and hashes: artwork-prompts.json

The body renderer samples the original angry artwork outside the shield coverage mask. Only the newly revealed body surfaces beneath the shield and its six-source-pixel painted-rim margin sample the targeted reconstruction. The shield is a rigid island of the original texture. No pre-rendered pose substitutions or primitive replacement character are used in this clip.
