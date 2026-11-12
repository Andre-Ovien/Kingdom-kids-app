import bpy,sys,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'source-assets/mpfb2/src'))
old_extension_path=bpy.utils.extension_path_user
def extension_path(package,*,path='',create=False):
 if package=='mpfb':
  dest=ROOT/'source-assets/mpfb-user'/path
  if create:dest.mkdir(parents=True,exist_ok=True)
  return str(dest)
 return old_extension_path(package,path=path,create=create)
bpy.utils.extension_path_user=extension_path
import mpfb
import addon_utils
addon_utils.enable('mpfb',default_set=True)
from mpfb.services.humanservice import HumanService
from mpfb.services.targetservice import TargetService
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
macro=TargetService.get_default_macro_info_dict()
macro.update(gender=1.0,age=.93,muscle=.48,weight=.45)
macro['race']={'african':1.0,'asian':0.0,'caucasian':0.0}
human=HumanService.create_human(macro_detail_dict=macro)
rig=HumanService.add_builtin_rig(human,'game_engine')
print('HUMAN',human.name,tuple(human.dimensions),len(human.data.vertices))
for bone in rig.data.bones:
 print('BONE',bone.name,tuple(bone.head_local),tuple(bone.tail_local))
eyes=HumanService.add_mhclo_asset(str(ROOT/'source-assets/eyes-low-poly/low-poly.mhclo'),human,asset_type='Eyes')
print('EYES',eyes,[(o.name,tuple(o.dimensions)) for o in bpy.data.objects])
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'probe-human.blend'))
