# Quaternius Ultimate Animated Animal Pack — native sources

Unmodified native Blender 2.79 source files downloaded from the creator’s public download folder on 2026-10-13. These files preserve the artist’s IK constraints and editable actions, unlike the baked glTF candidates. Modeling and animation refinement are to happen through the visible Blender application. Neither asset has been installed in the production game.

Creator: Quaternius. License: CC0 1.0 Universal. The creator’s primary pack page explicitly permits personal and commercial projects and labels the assets CC0: https://quaternius.com/packs/ultimateanimatedanimals.html

The exact public Drive file IDs, download URLs, byte counts, and SHA-256 hashes are recorded in source-metadata.json. LICENSE-CC0.txt contains the CC0 legal text. No payment, account connection, or generation credits were used. Temporary read-only audit copies remain untouched in /tmp.

## Donkey.blend

Objects: AnimalArmature and Donkey. 50 bones, connected 1002-vertex / 1022-face mesh. Eight existing materials include Eye_Dark and Eye_White. Active source action is Idle; Walk is an endpoint-closed 0–35 frame loop at 30 fps (1.166667 seconds). The source model Location X=4.0106859 is canceled by its Parent Inverse X=-4.0106859, leaving the mesh at world X=0; do not reset that location independently.

## Deer.blend

Objects: AnimalArmature and Deer. 46 bones, 1051 vertices / 1090 faces, with existing eyes and eight materials. Active source action is Idle; Walk is the same endpoint-closed 0–35 frame loop at 30 fps. This candidate avoids the older doe model’s nonclosed Run action and unresolved legacy action path.

## Shared native motion controls

IKFrontLeg.L / .R and IKBackLeg.L / .R are the editable paw controls. The front lower-leg IK chain has length 2; the rear lower-leg chain length 4; both use the supplied pole targets. The controller axes are oblique: changing only local Y would also change vertical position. Turn variants must preserve that coupling and be reviewed visually; do not blindly copy the elephant’s single-axis stride edit. Both models face Blender -Y, which exports to glTF +Z. Original artist actions and source geometry must remain intact; Save As separate working scenes before editing.

## Read-only motion measurements

Walk stance windows (35-frame period): front right 0–17, front left 15–32, back left 9–25, back right 27–8 across the loop. The front stance pace is 2.0731306 source world units/second and rear stance pace is 3.5880157; their mean is 2.8305732. Multiply by exported-model normalization scale for runtime speed. Front and rear authored stride speeds differ, so the mean is an approximation that requires visual review, not a proof of zero sliding.

Both native models use foot-control local-Y world axis (0, -0.3671556, -0.9301596), local-Z world axis (0, +0.9301596, -0.3671556). For a first left-turn study, proportionally scale the left paw controllers’ local Y and Z location values together about zero by 0.7, and right controllers by 1.3; reverse for right turn. This preserves the coupled stance plane and also scales swing height. Preserve original walk key timing and endpoint equality. Review the visible result before accepting this study. The Head local-Z axis is oblique; a modest world-Z head rotation is safer for steering.

Existing skinned eye materials require no new eye meshes. Donkey: Main, Main_Light, Main_Dark, Hooves, Hair, Muzzle, Eye_Dark, Eye_White. Deer: Main, Hooves, Muzzle, Main_Light, Main_Dark, Eye_Lighter, Eye_Black, Eye_White. Source materials are legacy diffuse colors; native glTF fallback retains their colors. Deer also has a Col vertex-color layer to inspect during export.
