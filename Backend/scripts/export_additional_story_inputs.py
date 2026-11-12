#!/usr/bin/env python3
"""Export only the five authored additions, without opening or changing a DB."""
import importlib.util
import json
from pathlib import Path

BACKEND=Path(__file__).resolve().parents[1]
source=BACKEND/'Core/apps/stories/catalogue_expansion_v1.py'
spec=importlib.util.spec_from_file_location('additional_stories',source)
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
output=BACKEND/'media/character_narration'
for directory in [output/'story_inputs',output/'story_inputs/additional']:
    directory.mkdir(parents=True,exist_ok=True)
    for story in module.STORIES:
        text=json.dumps({key:story[key] for key in ['slug','title','body']},
                        ensure_ascii=False,indent=2)+'\n'
        (directory/(story['slug']+'.json')).write_text(text,encoding='utf-8')
print(f'Exported {len(module.STORIES)} additive stories; no database was opened.')
