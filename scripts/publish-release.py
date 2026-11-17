#!/usr/bin/env python3
"""Publish an immutable, signed SemVer release and its Sparkle update feed."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
from versioning import version, release_entry

root=Path(__file__).resolve().parent.parent
folder=root/'dist/release'
revision=os.environ.get('RELEASE_REVISION') or os.environ.get('GITHUB_SHA')
assert revision, 'Missing release revision'
release_version=str(version(root));tag='v'+release_version
manifests=[json.loads(path.read_text()) for path in sorted(folder.glob('*.json'))]
expected={('macos','arm64'),('linux','x86_64')}
assert len(manifests)==len(expected) and {(m['platform'],m['arch']) for m in manifests}==expected, 'Missing or unexpected platform artifact'
checksums=[];assets=[]
for info in manifests:
    assert info['revision']==revision and info['version']==release_version, 'Artifact version/revision mismatch'
    path=folder/info['asset'];meta=folder/(info['asset']+'.json')
    assert path.parent==folder and path.is_file() and meta.is_file(), 'Missing release file'
    assert hashlib.sha256(path.read_bytes()).hexdigest()==info['sha256'], 'Artifact checksum mismatch'
    checksums.append(f'{info["sha256"]}  {path.name}\n');assets.extend([path,meta])
mac=next(info for info in manifests if info['platform']=='macos')
assert mac['notarized'] is True, 'Stable releases require Apple notarization'
assert len(base64.b64decode(mac['ed_signature'],validate=True))==64, 'Missing update signature'
feed=folder/'appcast.xml';xml=ET.parse(feed)
namespace='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items=xml.findall('./channel/item');assert len(items)==1, 'Expected one current update'
item=items[0];enclosure=item.find('enclosure');assert enclosure is not None
assert item.findtext(namespace+'version')==release_version, 'Update feed version mismatch'
assert enclosure.attrib['url']==f'https://github.com/rovnyart/vibechar/releases/download/{tag}/{mac["asset"]}', 'Update feed URL mismatch'
assert enclosure.attrib[namespace+'edSignature']==mac['ed_signature'], 'Update signature mismatch'
assert int(enclosure.attrib['length'])==(folder/mac['asset']).stat().st_size, 'Update length mismatch'
sums=folder/'SHA256SUMS';sums.write_text(''.join(sorted(checksums)));assets.extend([sums,feed])
entry=release_entry((root/'CHANGELOG.md').read_text(),release_version)
assert entry, 'Missing release changelog'
notes=folder/'release-notes.md'
notes.write_text(entry+'\n\n---\n\nmacOS 14+ · Apple Silicon; Linux x86_64 terminal client.\n'
    'The Mac app, terminal editor and vc launcher are updated together. Mac downloads are Developer ID signed and Apple notarized; in-app updates additionally verify Ed25519 signatures.\n\n'
    '```sh\ncurl -fsSL https://raw.githubusercontent.com/rovnyart/vibechar/main/install.sh | sh\n```\n\n'
    f'Source: `{revision}` · [Full changelog](https://github.com/rovnyart/vibechar/blob/{tag}/CHANGELOG.md)\n')
base=['--repo','rovnyart/vibechar']
existing=subprocess.run(['gh','release','view',tag,*base,'--json','isPrerelease,isDraft'],capture_output=True)
if existing.returncode==0:
    current=json.loads(existing.stdout)
    if not current['isPrerelease'] and not current['isDraft']:
        sha=subprocess.check_output(['gh','api',f'repos/rovnyart/vibechar/commits/{tag}','--jq','.sha'],text=True).strip()
        assert sha==revision, 'A published version is immutable and belongs to another commit'
        print('Release already published; existing assets preserved: '+tag)
        raise SystemExit(0)
    # A failed draft may already have a tag. Move only that unpublished tag
    # forward to a subsequent fix; --target alone cannot move an existing tag.
    reference=subprocess.run(['gh','api',f'repos/rovnyart/vibechar/git/ref/tags/{tag}','--jq','.object.sha'],capture_output=True,text=True)
    if reference.returncode==0 and reference.stdout.strip()!=revision:
        subprocess.run(['gh','api','--method','PATCH',f'repos/rovnyart/vibechar/git/refs/tags/{tag}',
                        '-f','sha='+revision,'-F','force=false'],check=True)
    elif reference.returncode and '404' not in reference.stderr:
        raise RuntimeError('Cannot verify the unpublished release tag')
    subprocess.run(['gh','release','upload',tag,*base,'--clobber',*map(str,assets)],check=True)
else:
    subprocess.run(['gh','release','create',tag,*base,'--target',revision,'--title','Vibechar '+release_version,
                    '--notes-file',str(notes),'--draft',*map(str,assets)],check=True)
subprocess.run(['gh','release','edit',tag,*base,'--target',revision,'--title','Vibechar '+release_version,
                '--draft=false','--prerelease=false','--latest','--notes-file',str(notes)],check=True)
print('Published Vibechar '+release_version)
