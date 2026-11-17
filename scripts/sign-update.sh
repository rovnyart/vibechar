#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PYKEY'
import base64,html,json,os,pathlib,shutil,subprocess,sys,tempfile,xml.etree.ElementTree as ET
root=pathlib.Path(sys.argv[1]);sys.path.insert(0,str(root/'scripts'))
from versioning import release_entry
folder=root/'dist/release';asset=folder/'vibechar-macos-arm64.zip'
metadata=asset.with_suffix('.zip.json');info=json.loads(metadata.read_text())
assert info['notarized'], 'Notarize the Mac archive before signing updates.'
tool=root/'apps/macos/.build/artifacts/sparkle/Sparkle/bin/generate_appcast'
key=os.environ.pop('SPARKLE_PRIVATE_KEY',None)
with tempfile.TemporaryDirectory(prefix='vibechar-appcast-') as temporary:
    stage=pathlib.Path(temporary);shutil.copy2(asset,stage/asset.name)
    notes=release_entry((root/'CHANGELOG.md').read_text(),info['version'])
    assert notes, 'The release needs a changelog entry.'
    (stage/asset.with_suffix('.html').name).write_text('<pre>'+html.escape(notes)+'</pre>')
    arguments=[str(tool),'--download-url-prefix',f'https://github.com/rovnyart/vibechar/releases/download/v{info["version"]}/',
        '--maximum-versions','1','--maximum-deltas','0','--embed-release-notes','--link','https://github.com/rovnyart/vibechar']
    arguments+=['--ed-key-file','-'] if key else ['--account','dev.vibechar.updates.v1']
    result=subprocess.run([*arguments,str(stage)],input=key.strip().encode() if key else None,capture_output=True)
    if result.returncode: raise SystemExit('Sparkle could not generate the signed update feed; check the update signing key.')
    feed=stage/'appcast.xml';xml=ET.parse(feed)
    enclosure=xml.find('./channel/item/enclosure');assert enclosure is not None
    signature=enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
    assert len(base64.b64decode(signature,validate=True))==64
    info['ed_signature']=signature
    metadata.write_text(json.dumps(info,indent=2)+'\n')
    shutil.copy2(feed,folder/'appcast.xml')
print('Generated Sparkle appcast and Ed25519-signed update archive')
PYKEY
