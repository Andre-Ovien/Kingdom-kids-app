# Wildfire Games — isolated animal source candidates

Unmodified original 0 A.D. art files acquired from the project’s official archived repository on 2026-10-13. The exact repository commit, original paths, URLs, SHA-256 hashes, license, and audit findings are saved in source-metadata.json. No source models have been edited or added to Kingdom Kids. These are optional review candidates, not accepted replacements.

Primary publisher: https://github.com/0ad/0ad

## License and credits

All acquired files are in the original art directory. LICENSE.txt is the exact original art license notice: CC BY-SA 3.0, commercial and noncommercial use permitted. Required credit: **Wildfire Games — https://www.wildfiregames.com/ — CC BY-SA 3.0 https://creativecommons.org/licenses/by-sa/3.0/**. Redistributed assets and any modified art must keep that license. This candidate folder does not contain the game engine or executable software. Asset source and credits are preserved separately from Kingdom Kids application code.

This differs from the CC0 Quaternius donors. Retain that distinction when deciding which final art to publish.

## Single-file native import

The animation files themselves contain the animal mesh, skin controller, full skeleton/visual scene, and animation. Import a WALK file directly through visible Blender File → Import → Collada (.dae) (Legacy). **No separate mesh/animation retargeting is necessary for the walking scene.** Do not run conversion scripts or Blender CLI. The official Blender 4.5 manual lists Collada as a supported legacy format: https://docs.blender.org/manual/en/4.5/files/import_export/collada.html

| Animal | Complete walking scene | Texture | Read-only audit |
|---|---|---|---|
| Camel | animation/quadraped/camel_walk.dae | textures/skins/skeletal/animal_camel_a.png (dark brown), _b.png (beige), _c.png (light brown) | 48 skinned joints; 94 animated nodes; 41 samples over 1.333333 seconds, exactly closed matrices |
| Lion | animation/quadraped/lion_walk.dae | textures/skins/skeletal/animal_lion.png | 27 skinned joints; 30 animated nodes; 101 samples over 3.33333 seconds, exactly closed matrices |
| Giraffe | animation/quadraped/giraffe_adult_walk.dae | textures/skins/skeletal/animal_giraffe.png or animal_giraffeb.png | 31 skinned joints; 35 animated nodes; 101 samples over 3.33333 seconds; small right rear foot endpoint mismatch up to 0.011968 matrix value |

Corresponding *_idle_01.dae files also contain complete skinned scenes and idle animation. All geometry is hand-authored game art; no generative tool or payment was used. Source animal model files and original actor XMLs are retained for provenance, bone mappings, and optional later idle transfer. The XMLs are descriptive source data, not instructions or software to execute.

## Native review checklist

Start a separate working Blender scene and import only one complete WALK .dae candidate. Inspect its unit system and standing bounds; do not normalize from local mesh arrays because the visual scene and bind matrices affect real size. Camel declares metres; older Lion/Giraffe files declare centimetres. Native importer unit conversion must be observed, not guessed. Reuse the existing garden viewer’s posed-mesh normalization only after a proper native export.

Assign the matching source diffuse texture through native Shader Editor to a Principled BSDF. These game assets use external actor XML texture declarations, so Collada material import may not connect the skin image automatically. Preserve original UVs and skinned eyes. Preview the actual walk, all four feet, head connection, and turn approach before accepting it.

Camel and Lion sample endpoint transforms match exactly. Giraffe needs a small native loop correction: inspect frame 0 and its end frame at the native imported fps, copy the starting pose to the loop endpoint if it shows a seam, then check foot contact again. Do not treat successful XML parsing or file import as visual approval. No native Blender import has yet been performed by this read-only audit.

## Rig labels

Camel skin bones include Camelus_Pelvis, Camelus_Spine/Spine1/Spine2, Camelus_Neck_01–04, Camelus_Head, Camelus_Arm/Forearm/Hand/Hoof_L/R and Camelus_Thigh/Leg/Foreleg/Shin/Foot/Hoof_back_L/R. Extra prop and rig control nodes are already sampled in the action.

Lion’s legacy skin joint IDs retain Horse_* names despite being the lion model. These are the original author’s names; do not replace or assume the geometry is a horse. The actual geometry, original actor XML, skin texture, and dedicated lion_walk animation identify it as Lion.

Giraffe joints include main_pelvis, spine_01/02, spine_neck, neck_01/02/03, head, left/right_f_leg_*, left/right_r_leg_*, left/right_f_foot, left/right_r_foot, and tail_01–03.
