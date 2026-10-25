#!/usr/bin/env python3
"""Verify dimensions/typography and protected engines against pre-restyle git tree."""
from pathlib import Path
import subprocess,re,json,hashlib
root=Path(__file__).resolve().parent.parent
baseline=json.loads((root/'QA/RestyleScopeBaseline.json').read_text())
def calls(text):
 result=[]
 for m in re.finditer(r'\.(?:frame|padding|spacing|offset|position|alignmentGuide|controlSize|font|tracking|lineSpacing|fixedSize|layoutPriority)\(',text):
  start=m.start();i=m.end();depth=1;quoted=False;escaped=False
  while depth and i<len(text):
   c=text[i]
   if quoted:
    if escaped:escaped=False
    elif c=='\\':escaped=True
    elif c=='"':quoted=False
   elif c=='"':quoted=True
   elif c=='(':depth+=1
   elif c==')':depth-=1
   i+=1
  result.append(text[start:i])
 return result
geometry=[];protected=[]
for path,h in baseline['source_sha256'].items():
 now=(root/path).read_text()
 if 'SculptShowApp/' in path:
  if baseline['layout_calls'][path]!=calls(now):geometry.append(path)
 if any(x in path for x in ['SculptShowCore/','SculptLTCCore/']) or Path(path).name in ['PlaybackEngine.swift','RoutedAudioEngine.swift','ShowStore.swift','VideoPlayback.swift','VideoVoice.swift','OSCControl.swift','MIDIControl.swift','OutputMeterMonitor.swift','PlaybackPositionView.swift','VideoSoundtrack.swift','SculptDAWLaunchBridge.swift','SculptDAWSessionImport.swift','ConditionalLoopRealtime.swift','LTCRealtimeState.swift','CenteringPanControl.swift']:
  if hashlib.sha256((root/path).read_bytes()).hexdigest()!=h:protected.append(path)
report={'baseline':baseline['base_commit'],'geometry_or_typography_changed':geometry,'protected_sources_changed':protected,'authorized_layout_changes':baseline.get('authorized_layout_changes',{}),'pass':not geometry and not protected}
print(json.dumps(report,indent=2))
if len(__import__('sys').argv)>1:Path(__import__('sys').argv[1]).write_text(json.dumps(report,indent=2)+'\n')
assert report['pass']
