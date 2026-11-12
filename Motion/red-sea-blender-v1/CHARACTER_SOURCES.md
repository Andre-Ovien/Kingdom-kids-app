# Red Sea character source record

Created locally with Blender 4.5.9 LTS on 2026-10-10. These are native continuous
human meshes with weighted skeletons, fitted clothing, attached hair, anatomical
hands and feet. The app receives whole rendered frames, rather than slices of
illustrations. The editable source is `red-sea-characters.blend`.

## Source assets and licenses

The MakeHuman Community's MPFB2 repository supplied the human base, African
appearance targets, age and body shape targets, `game_engine` rig, and rig
weights. The checked source revision is
`d0a32e57a7f915cb2f2b95410e2117648c7bbb7e`:

- Repository: https://github.com/makehumancommunity/mpfb2
- License explanation: https://github.com/makehumancommunity/mpfb2/blob/master/LICENSE.md
- General license: https://static.makehumancommunity.org/about/license.html

MPFB program code is GPLv3. Its graphical assets are CC0 1.0, and its license
explicitly treats rendered images and saved models as unrestricted output.
The mobile bundle contains rendered images and metadata only; it contains no
MPFB program code. Copies of both license texts remain in
`source-assets/mpfb2/LICENSE.CODE.md` and `LICENSE.ASSETS.md`.

The system asset pack supplied `old_african_male`, `young_african_male`,
`young_african_female` skin materials/textures, `eyes/low-poly`, brown eye
material, and `hair/short02` and `hair/afro01`. These are from the official
CC0 system collection. The eyes and hair `.mhclo` headers also explicitly
record their September 2020 CC0 release.

- Pack page: https://static.makehumancommunity.org/assets/assetpacks/makehuman_system_assets.html
- Download: https://files2.makehumancommunity.org/asset_packs/makehuman_system_assets/makehuman_system_assets_cc0.zip
- SHA-256: `b542127a8e25547c7c29c19f2d1d2adb9a664c80396ecd694095dbc8028a0107`

The continuous fitted robe is Mindfront's `mindfront_kimono` mesh. Its `.mhclo`
header names Mindfront (Sweden) as the author and explicitly specifies CC0.
The hem, cloth shading, colors, belts and front treatment are modified for
this scene. The other robe that was investigated, `mycenaean_tunic`, is not
used in these characters or runtime images.

- Pack page: https://static.makehumancommunity.org/assets/assetpacks/dress01.html
- Download: https://files2.makehumancommunity.org/asset_packs/dress01/dress01_cc0.zip
- SHA-256: `f49ba54a3c93acd3c3307cc5a96cfc65daf8abfed9212a7e580791d821c9e93a`

The staff, sandals, beard/moustache geometry, tunic panel, sash, lighting and
poses are authored in the local scripts. The existing dark-skinned Moses
story illustration guided the purple robe, cream tunic and red sash. The
new figure is an elder character interpretation, not a historically verified
portrait or an exact recreation of the story illustration.

## Animation and rendering

`build_characters.py` creates Moses. `animate_moses.py` authors his ready
pose and 63-frame, 2.6-second staff lift, sea strike and settling action.
The staff is placed in the enclosed hand grip, the feet stay planted, and
contact at 1.0 seconds projects forward toward the sea. The torso faces the
lane while the head shows a bearded profile.

`build_travellers.py` creates three dark-skinned travellers, each with one
front idle frame, an eight-frame native turn, a 24-frame rear walking cycle,
and one rear idle frame. Turn end, walk start and rear idle share the same
neutral skeleton pose. The walk moves complete weighted limbs and clothing.
The cycle loops by sampling phase 0 through 23/24, without duplicating phase 1.

Frames use warm upper-right light and cool sea fill, transparent RGBA PNG,
fixed orthographic camera cells (Moses 320 x 384; travellers 128 x 192), and
fixed projected ground anchors. `character-source-manifest.json` records
positive clip durations, frame globs, foot anchors and body heights. The
parent packing script generates the runtime atlases.

Blender is used offline to author and render these assets. Native skeletal
deformation and rendered lighting are preserved in the sprites, but the
phone is not running real-time 3D simulation, cloth physics or Blender.
