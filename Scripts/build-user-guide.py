#!/usr/bin/env python3
"""Render the maintained Italian Markdown guide offline; verify every cited source file."""
from pathlib import Path
import html, re, hashlib, json
root = Path(__file__).resolve().parent.parent
source = root/'docs/SCULPT_SHOW_GUIDA_UTENTE_IT.md'
text = source.read_text()
files = list((root/'Sources').rglob('*.swift')) + list((root/'Sources').rglob('*.c')) + list((root/'Sources').rglob('*.h')) + [root/'Package.swift']
by_name = {p.name:p for p in files}
references = sorted(set(re.findall(r'\b[\w.-]+\.(?:swift|h|c)\b',text)))
missing = [name for name in references if name not in by_name]
assert not missing, 'Missing guide source references: '+repr(missing)
assert 'exclude: ["TimecodeGenerator.swift"]' in (root/'Package.swift').read_text()
assert '+ list.rules + cue.rules' in (root/'Sources/SculptShowCore/Rules.swift').read_text()
assert 'maximumCues = 8' in (root/'Sources/SculptShowCore/CueVideo.swift').read_text()
assert 'static let maximumVoices = 64' in (root/'Sources/SculptShowApp/RoutedAudioEngine.swift').read_text()
assert '"TRIGGER"' in (root/'Sources/SculptShowApp/WorkspaceView.swift').read_text()
assert 'SENDS · MIDI / OSC / TIMECODE' in (root/'Sources/SculptShowApp/CueMessageEditor.swift').read_text()
assert 'ConfirmedNumberField' in (root/'Sources/SculptShowApp/VideoTransformEditor.swift').read_text()
assert 'playbackRange' in (root/'Sources/SculptShowCore/Show.swift').read_text()
checks = ['IN/OUT','MTC','LTC','backup','Preflight','Bridge','MIDI','OSC','Keep proportions','Stretch','Crop','sample rate','Rules','Monitor','Normalizzazione','Scorciatoie','Invio']
for term in checks: assert term.casefold() in text.casefold(),term
hashes = {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}
fingerprint = hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest()
report = {'version':'0.24.1','branch':'fix/marker-loop-bridge-workspace','pull_request':2,'edition':'2026-10-25','source_fingerprint_sha256':fingerprint,'guide_markdown_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'cited_sources':{name:str(by_name[name].relative_to(root)) for name in references},'source_sha256':hashes,'verification_scope':'Source-reference/fingerprint/resource assertions plus manual code review; not hardware certification. See delivery checklist for executed build/runtime tests.'}
(root/'docs/SCULPT_SHOW_VERIFICA_GUIDA_IT.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
def inline(value):
    value=html.escape(value)
    value=re.sub(r'`([^`]+)`',r'<code>\1</code>',value)
    value=re.sub(r'\*\*([^*]+)\*\*',r'<strong>\1</strong>',value)
    return value
headings=[]; body=[]; paragraph=[]; current_list=None

def flush():
    if paragraph: body.append('<p>'+inline(' '.join(paragraph))+'</p>');paragraph.clear()
def close_list():
    global current_list
    if current_list:body.append('</'+current_list+'>');current_list=None
for line in text.splitlines():
    match=re.match(r'^(#{1,3}) (.+)$',line)
    if match:
        flush();close_list();level=len(match[1]);title=match[2];anchor='cap-'+str(len(headings));headings.append((level,title,anchor));body.append(f'<h{level} id="{anchor}">{inline(title)}</h{level}>');continue
    item=re.match(r'^(- |\d+\. )(.+)$',line)
    if item:
        flush();kind='ul' if item[1]=='- ' else 'ol'
        if current_list!=kind:close_list();body.append('<'+kind+'>');current_list=kind
        body.append('<li>'+inline(item[2])+'</li>');continue
    if not line.strip():flush();close_list();continue
    close_list();paragraph.append(line.strip())
flush();close_list()
toc='<nav aria-label="Indice"><h2>Indice</h2><ul>'+''.join(f'<li><a href="#{a}">{inline(t)}</a></li>' for l,t,a in headings if l==2)+'</ul></nav>'
css='''html{scroll-behavior:smooth}body{max-width:980px;margin:auto;padding:28px 32px;background:#171c24;color:#e8edf5;font:16px/1.65 -apple-system,BlinkMacSystemFont,sans-serif}h1,h2,h3{color:#efd6a3;line-height:1.25}h2{margin-top:2.2em;border-bottom:1px solid #4b5360;padding-bottom:.5em}a{color:#80ccff}code{font-size:.9em;overflow-wrap:anywhere;color:#b8e6f5}nav{background:#222c38;padding:16px;border-radius:10px}li{margin-bottom:.4em}footer{font-size:12px;overflow-wrap:anywhere;margin-top:40px;color:#aab6c5}@media print{body{background:white;color:black;max-width:none;font-size:10pt}h1,h2,h3{color:black}a,code{color:#135}nav{background:#eee}h2{break-after:avoid}li{break-inside:avoid}}'''
page='<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>SCULPT SHOW — Guida utente italiana 0.24.1</title><style>'+css+'</style></head><body>'+body[0]+toc+''.join(body[1:])+f'<footer>Guida offline · fingerprint sorgenti: {fingerprint}. Il rapporto JSON separato elenca hash e riferimenti. Consultare la checklist della consegna per i test effettivamente eseguiti.</footer></body></html>'
assert page.count('<h2 id=')==24
for _,_,anchor in headings:assert 'id="'+anchor+'"' in page
(root/'docs/SCULPT_SHOW_GUIDA_UTENTE_IT.html').write_text(page)
print(f'Guide verified/rendered: 24 chapters, {len(references)} cited source files, fingerprint {fingerprint}')
