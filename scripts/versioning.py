#!/usr/bin/env python3
"""Stable SemVer, Conventional Commits and retry-safe release preparation."""
import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = 'rovnyart/vibechar'
TYPES = {'feat','fix','perf','refactor','docs','style','test','build','ci','chore','revert'}
PACKAGES = {'vibechar-core','vibechar-bridge','vibechar','vc'}
HEADER = re.compile(r'^(\w+)(?:\(([^()\r\n]+)\))?(!)?: (\S.*)$', re.I)


@dataclass(frozen=True, order=True)
class Version:
    major: int
    minor: int
    patch: int

    @classmethod
    def parse(cls, text):
        match = re.fullmatch(r'v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', text)
        if not match:
            raise ValueError('Use a stable version such as 1.2.3 (without prerelease suffixes).')
        return cls(*(int(x) for x in match.groups()))

    def __str__(self):
        return f'{self.major}.{self.minor}.{self.patch}'

    def bump(self, kind):
        if kind == 'major': return Version(self.major+1,0,0)
        if kind == 'minor': return Version(self.major,self.minor+1,0)
        if kind == 'patch': return Version(self.major,self.minor,self.patch+1)
        raise ValueError('Choose patch, minor, major or exact.')


def cargo_version(text):
    section = text.split('[workspace.package]',1)[1].split('\n[',1)[0]
    return Version.parse(re.search(r'^version\s*=\s*"([^"]+)"',section,re.M)[1])


def version(root=ROOT):
    return cargo_version((root/'Cargo.toml').read_text())


def set_version(root, target):
    path = root/'Cargo.toml'; text = path.read_text()
    text, count = re.subn(r'(?m)(^version\s*=\s*")[^"]+("\s*$)',
                         lambda m: m[1]+str(target)+m[2],text,count=1)
    if count != 1: raise ValueError('Missing workspace version.')
    path.write_text(text)
    lock = root/'Cargo.lock'; blocks = lock.read_text().split('[[package]]')
    changed = set()
    for i,block in enumerate(blocks[1:],1):
        name = re.search(r'^name = "([^"]+)"',block,re.M)
        if name and name[1] in PACKAGES and not re.search(r'^source = ',block,re.M):
            blocks[i] = re.sub(r'(?m)^version = "[^"]+"',f'version = "{target}"',block,count=1)
            changed.add(name[1])
    if changed != PACKAGES: raise ValueError('Workspace packages are missing from Cargo.lock.')
    lock.write_text('[[package]]'.join(blocks))


def git(root, *args):
    return subprocess.check_output(['git','-C',str(root),*args],text=True).strip()


def commits(root, base=None, head='HEAD'):
    data = git(root,'log','--reverse','--format=%H%x00%P%x00%B%x00',f'{base}..{head}' if base else head)
    fields = data.split('\0'); result = []
    for i in range(0,len(fields)-2,3):
        sha,parents,message = (x.strip() for x in fields[i:i+3])
        if len(parents.split())>1: continue
        subject = message.splitlines()[0]
        match = HEADER.fullmatch(subject)
        kind,scope,description = (match[1].lower(),match[2],match[4]) if match else ('other',None,subject)
        breaking = bool(match and match[3]) or bool(re.search(r'(?m)^BREAKING(?: CHANGE|-CHANGE):\s*\S',message))
        if kind=='chore' and scope=='release': continue
        result.append(dict(sha=sha,subject=subject,kind=kind,scope=scope,description=description,breaking=breaking))
    return result


def lint(root, base, head='HEAD'):
    invalid = [c['subject'] for c in commits(root,base,head) if not HEADER.fullmatch(c['subject']) or c['kind'] not in TYPES]
    if invalid: raise ValueError('Use Conventional Commits, e.g. feat(editor): add a tool. Invalid:\n'+'\n'.join(invalid))


def release_entry(text, target):
    match = re.search(r'(?ms)^## \['+re.escape(str(target))+r'\][^\n]*\n(.*?)(?=^## |\Z)',text)
    return match[1].strip() if match else None


def changelog_entry(target, changes):
    groups = [('Breaking changes',[c for c in changes if c['breaking']]),
              ('Added',[c for c in changes if c['kind']=='feat' and not c['breaking']]),
              ('Fixed',[c for c in changes if c['kind'] in {'fix','revert'} and not c['breaking']]),
              ('Performance',[c for c in changes if c['kind']=='perf' and not c['breaking']]),
              ('Changed',[c for c in changes if c['kind'] not in {'feat','fix','revert','perf'} and not c['breaking']])]
    sections = []
    for title,items in groups:
        if not items: continue
        lines = []
        for c in items:
            description = re.sub(r'\s*\[(?:skip ci|ci skip|skip actions)\]\s*','',c['description'],flags=re.I)
            scope = f"**{c['scope']}**: " if c['scope'] else ''
            lines.append(f"- {scope}{description} ([{c['sha'][:7]}](https://github.com/{REPOSITORY}/commit/{c['sha']}))")
        sections.append('### '+title+'\n\n'+'\n'.join(lines))
    return '\n\n'.join(sections) or '### Changed\n\n- Maintenance release.'


def write_changelog(root, target, body):
    path = root/'CHANGELOG.md'
    text = path.read_text() if path.exists() else '# Changelog\n\nAll notable changes to Vibechar.\n\n'
    text = re.sub(r'(?ms)^## \['+re.escape(str(target))+r'\][^\n]*\n.*?(?=^## |\Z)','',text)
    date = datetime.now(timezone.utc).date().isoformat()
    entry = f'## [{target}](https://github.com/{REPOSITORY}/releases/tag/v{target}) — {date}\n\n{body}\n\n'
    index = re.search(r'(?m)^## ',text)
    position = index.start() if index else len(text)
    path.write_text(text[:position].rstrip()+'\n\n'+entry+text[position:].lstrip())


def prepare(root, latest, published, bump, exact, run_id, automatic=False, validation_base=None):
    if not re.fullmatch(r'\d+',run_id): raise ValueError('Release run ID must be numeric.')
    if git(root,'status','--porcelain','--untracked-files=no'): raise ValueError('Release preparation needs a clean checkout.')
    previous = git(root,'log','--format=%H','-1','--grep',f'^Release-Run: {run_id}$')
    if previous:
        target = cargo_version(git(root,'show',f'{previous}:Cargo.toml'))
        return dict(version=str(target),tag='v'+str(target),revision=previous,release=str(target) not in published)
    if bump=='exact' and not exact: raise ValueError('Enter the exact version when choosing exact.')
    if bump!='exact' and exact: raise ValueError('Choose exact to supply an explicit version.')
    current = version(root)
    base = 'v'+str(latest) if latest else None
    changes = commits(root,base)
    if latest:
        lint(root,base)
        if automatic and not changes:
            return dict(version=str(latest),tag='v'+str(latest),revision=git(root,'rev-parse','HEAD'),release=False)
    elif validation_base and set(validation_base)!={'0'}:
        lint(root,validation_base)
    breaking = any(c['breaking'] for c in changes)
    if latest is None:
        target = Version(1,0,0)
        if exact and Version.parse(exact)!=target: raise ValueError('The first version must be 1.0.0.')
    elif current > latest:
        target = current  # A failed build reserved this unreleased version; retry it.
        if exact and Version.parse(exact)!=target: raise ValueError(f'Finish the pending {target} release before changing its version.')
        if breaking and target.major<=latest.major: target=latest.bump('major')
    else:
        if bump=='exact':
            if not exact: raise ValueError('Enter the exact version when choosing exact.')
            target = Version.parse(exact)
        else:
            if exact: raise ValueError('Choose exact to supply an explicit version.')
            target = latest.bump('major' if automatic and breaking else bump)
        if target<=latest: raise ValueError('The release version must increase.')
        if breaking and target.major<=latest.major: raise ValueError('Breaking changes require a major version.')
    path=root/'CHANGELOG.md'
    curated = release_entry(path.read_text(),target) if latest is None and path.exists() else None
    set_version(root,target)
    write_changelog(root,target,curated or changelog_entry(target,changes))
    subprocess.run(['git','-C',str(root),'add','Cargo.toml','Cargo.lock','CHANGELOG.md'],check=True)
    subprocess.run(['git','-C',str(root),'commit','--allow-empty','-m',f'chore(release): {target} [skip ci]','-m',f'Release-Run: {run_id}'],check=True,capture_output=True)
    return dict(version=str(target),tag='v'+str(target),revision=git(root,'rev-parse','HEAD'),release=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    sub.add_parser('current')
    check=sub.add_parser('lint');check.add_argument('--base',required=True);check.add_argument('--head',default='HEAD')
    release=sub.add_parser('prepare');release.add_argument('--bump',choices=['patch','minor','major','exact'],default='minor')
    release.add_argument('--version',default='');release.add_argument('--run-id',required=True)
    release.add_argument('--automatic',action='store_true');release.add_argument('--validation-base')
    release.add_argument('--output',default='dist/release-plan.json')
    args=parser.parse_args()
    if args.command=='current': print(version());return
    if args.command=='lint': lint(ROOT,args.base,args.head);return
    releases=json.loads(subprocess.check_output(['gh','release','list','--repo',REPOSITORY,'--limit','100','--json','tagName,isDraft,isPrerelease']))
    published=set()
    for item in releases:
        if item['isDraft'] or item['isPrerelease']: continue
        try: published.add(str(Version.parse(item['tagName'])))
        except ValueError: pass  # Historical build-<sha> archives are not SemVer releases.
    latest=max((Version.parse(x) for x in published),default=None)
    plan=prepare(ROOT,latest,published,args.bump,args.version,args.run_id,args.automatic,args.validation_base)
    path=ROOT/args.output;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(plan,indent=2)+'\n')
    print(json.dumps(plan))


if __name__=='__main__':
    try: main()
    except (ValueError,subprocess.CalledProcessError) as error: raise SystemExit(str(error))
