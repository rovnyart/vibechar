#!/usr/bin/env python3
"""Embed the pinned Sparkle runtime, keeping only ARM code and required helpers."""
from pathlib import Path
import shutil
import subprocess
import sys

root=Path(__file__).resolve().parent.parent
app=Path(sys.argv[1])
artifacts=root/'apps/macos/.build/artifacts/sparkle/Sparkle'
candidates=list((artifacts/'Sparkle.xcframework').glob('macos-*/Sparkle.framework'))
assert len(candidates)==1, 'Resolve the pinned Sparkle package before embedding it.'
framework=app/'Contents/Frameworks/Sparkle.framework'
framework.parent.mkdir(parents=True,exist_ok=True)
if framework.exists(): shutil.rmtree(framework)
shutil.copytree(candidates[0],framework,symlinks=True)
# Vibechar is not sandboxed; Sparkle supports removing these unused services.
for path in [framework/'Versions/B/XPCServices',framework/'XPCServices']:
    if path.is_symlink(): path.unlink()
    elif path.exists(): shutil.rmtree(path)
magic={b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf',b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf'}
count=0
for path in framework.rglob('*'):
    if path.is_symlink() or not path.is_file(): continue
    with path.open('rb') as stream: header=stream.read(4)
    if header not in magic: continue
    architectures=subprocess.check_output(['lipo','-archs',str(path)],text=True).split()
    assert 'arm64' in architectures, 'Sparkle runtime lacks ARM code.'
    if architectures!=['arm64']:
        temporary=path.with_name(path.name+'.arm64')
        subprocess.run(['lipo',str(path),'-thin','arm64','-output',str(temporary)],check=True)
        temporary.chmod(path.stat().st_mode);temporary.replace(path)
    count+=1
assert count==3, 'Unexpected Sparkle runtime layout; review its embedded helpers.'
shutil.copy2(artifacts/'LICENSE',app/'Contents/Resources/Sparkle License.txt')
print('Embedded Sparkle: ARM framework and two update helpers')
