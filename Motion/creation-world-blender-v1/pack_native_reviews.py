"""Create contact sheets and review metadata from actual Flutter widget PNGs."""
import json
from pathlib import Path
from PIL import Image, ImageDraw

ROOT=Path(__file__).resolve().parents[1]
for folder,frames in (('creation-world-blender-v1',48),('wise-builders-blender-v1',72)):
    directory=ROOT/folder/'review/native'
    sheet=Image.new('RGB',(585,892),'#eeeadd');draw=ImageDraw.Draw(sheet)
    for number in (1,2,3):
        for row,state in enumerate(('first','completed')):
            path=directory/f'round-{number}-{state}.png'
            image=Image.open(path).convert('RGB');image.thumbnail((195,422),Image.Resampling.LANCZOS)
            x=(number-1)*195;y=row*446
            draw.text((x+7,y+5),f'Round {number} · {state}',fill='#1b3933')
            sheet.paste(image,(x,y+24))
    sheet.save(directory/'all-rounds-native-contact.png',optimize=True)
    (directory/'native-review-proof.json').write_text(json.dumps({
        'actual_flutter_widget':True,'source_test':'Frontend/mobile/test/creation_builders_native_capture_test.dart',
        'logical_viewport':[390,844],'still_pixel_ratio':2,'motion_pixel_ratio':1,
        'first_and_completed_rounds':[1,2,3],'motion_frame_count':frames,'motion_fps':12,
        'graphics':'Original Blender meshes and rendered pose atlases; no graphic stand-ins.',
        'interaction':'Real tap placement/assembly and day/storm controls; submission commands asserted.',
    },indent=2))
    print(directory/'all-rounds-native-contact.png')
