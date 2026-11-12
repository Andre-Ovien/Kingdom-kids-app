# Creation living world source

`creation-world-source.blend` contains the original editable tile meshes, materials, fish fin and bird wing keyframes, and a completed world scene. Original Ark goat and rabbit sculptures and quadruped rigs are reused with their native provenance.

The app permits many landscapes while retaining the Bible day sequence. Water must connect source cell 0 with sea cell 15 through neighboring tiles. Land must form one meadow; forest tiles occupy ground and can block routes. Fish swim through connected water, birds land in forest, and animals walk through neighboring meadow cells. Gameplay positions are calculated in Flutter; creature poses come from Blender renders.

`review-completed-world.png` is a native Blender still. `review-creature-motion.gif` contains unchanged Blender fish and bird frames. `preview.html` is a local interactive review of the placement rules; it has passed a JavaScript syntax check but has not been browser-verified.

Rebuild exports with Blender, then pack the unchanged rendered frames with Pillow:

```sh
Blender --background --threads 4 --python Motion/creation-world-blender-v1/author_creation_world.py -- --render
python Motion/creation-world-blender-v1/pack_assets.py
```

The mobile loader decodes only the textures needed by the round, with a 40 MiB cap, and reads Ark animal atlas registration anchors from its manifest. Terrain sprites share source registration rectangle `[40,49,184,187]` so neighboring ground faces visually join. Sources and authoring scripts stay in this folder; only packed images ship in the mobile bundle.
