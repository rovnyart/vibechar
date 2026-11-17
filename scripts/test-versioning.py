#!/usr/bin/env python3
"""Real Git fixtures for version reservation, retries and Conventional Commits."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from versioning import Version,commits,lint,prepare,release_entry,version

SOURCE=Path(__file__).resolve().parent.parent


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='vibechar-version-test-')
        self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        for name in ['Cargo.toml','Cargo.lock']:
            shutil.copy2(SOURCE/name,self.root/name)
        (self.root/'CHANGELOG.md').write_text('# Changelog\n\n## [1.0.0] — 2026-11-17\n\n### Added\n\n- Curated first release.\n')
        self.git('init','-q');self.git('config','user.name','Fixture');self.git('config','user.email','fixture@example.invalid')
        self.commit('feat: initial editor')

    def git(self,*args):
        return subprocess.check_output(['git','-C',str(self.root),*args],text=True).strip()

    def commit(self,message):
        self.git('add','.');self.git('commit','--allow-empty','-qm',message)

    def first(self):
        plan=prepare(self.root,None,set(),'minor','','100',automatic=True)
        self.git('tag','v1.0.0')
        return plan

    def plan(self,run='101',bump='minor',exact='',automatic=True):
        return prepare(self.root,Version(1,0,0),{'1.0.0'},bump,exact,run,automatic)

    def test_first_is_one_and_keeps_curated_notes(self):
        plan=prepare(self.root,None,set(),'minor','','100',automatic=True)
        self.assertEqual(plan['version'],'1.0.0')
        self.assertEqual(version(self.root),Version(1,0,0))
        self.assertIn('Curated first release.',release_entry((self.root/'CHANGELOG.md').read_text(),Version(1,0,0)))
        self.assertEqual(self.git('show','-s','--format=%s'),'chore(release): 1.0.0 [skip ci]')

    def test_same_run_reuses_commit_and_does_not_double_bump(self):
        self.first();self.commit('feat(editor): add selections')
        first=self.plan();count=self.git('rev-list','--count','HEAD')
        self.assertEqual(self.plan(),first)
        self.assertEqual(self.git('rev-list','--count','HEAD'),count)

    def test_failed_release_keeps_version_when_fixed_in_new_run(self):
        self.first();self.commit('feat: add a tool');self.plan()
        self.commit('fix: repair that tool');second=self.plan(run='102')
        self.assertEqual(second['version'],'1.1.0')
        self.assertEqual(version(self.root),Version(1,1,0))
        notes=(self.root/'CHANGELOG.md').read_text()
        self.assertEqual(notes.count('## [1.1.0]'),1)
        self.assertIn('repair that tool',notes)
        self.assertIn('Curated first release.',notes)

    def test_ordinary_fix_uses_requested_default_minor(self):
        self.first();self.commit('fix: correct a label')
        self.assertEqual(self.plan()['version'],'1.1.0')

    def test_manual_patch_and_exact(self):
        self.first();self.commit('fix: correct a label')
        self.assertEqual(self.plan(bump='exact',exact='v1.4.2',automatic=False)['version'],'1.4.2')

    def test_patch(self):
        self.first();self.commit('fix: correct a label')
        self.assertEqual(self.plan(bump='patch',automatic=False)['version'],'1.0.1')

    def test_major(self):
        self.first();self.commit('feat: improve editor')
        self.assertEqual(self.plan(bump='major',automatic=False)['version'],'2.0.0')

    def test_breaking_change_gets_major(self):
        self.first();self.commit('feat(core)!: change format')
        self.assertEqual(self.plan()['version'],'2.0.0')

    def test_breaking_footer_refuses_manual_minor(self):
        self.first();self.commit('fix(core): change format\n\nBREAKING-CHANGE: older readers need migration')
        before=(self.root/'Cargo.toml').read_bytes()
        with self.assertRaisesRegex(ValueError,'Breaking changes'):
            self.plan(automatic=False)
        self.assertEqual((self.root/'Cargo.toml').read_bytes(),before)

    def test_published_run_is_idempotent_and_automatic_empty_push_is_skipped(self):
        self.first()
        same=prepare(self.root,Version(1,0,0),{'1.0.0'},'minor','','100',True)
        self.assertFalse(same['release'])
        self.assertFalse(self.plan()['release'])

    def test_lint_reports_bad_subject(self):
        base=self.git('rev-parse','HEAD');self.commit('random commit')
        with self.assertRaisesRegex(ValueError,'Conventional Commits'): lint(self.root,base)

    def test_version_does_not_go_backwards(self):
        self.first();self.commit('feat: improve editor')
        with self.assertRaisesRegex(ValueError,'increase'): self.plan(bump='exact',exact='1.0.0',automatic=False)

    def test_stable_version_parser(self):
        for invalid in ['1.0','01.2.3','1.2.3-beta','1.2.3\n','1.2.3; echo bad']:
            with self.subTest(invalid=invalid),self.assertRaises(ValueError): Version.parse(invalid)


if __name__=='__main__': unittest.main()
