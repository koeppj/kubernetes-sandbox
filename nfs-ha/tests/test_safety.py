"""Mocked checks for preflight, package installation, and preparation staging."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from argparse import Namespace

spec = importlib.util.spec_from_file_location('ha', Path(__file__).parents[1] / 'scripts/nfs_ha.py')
ha = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ha)


def fixture():
    return {'host': ha.HOST, 'pv_path': '/dev/sdz3', 'parent': 'sdz',
            'pvs': [{'pv_name': '/dev/sdz3', 'pv_uuid': ha.PV_UUID, 'vg_name': ha.VG, 'pv_free': 2692 * ha.GIB}],
            'vgs': [{'vg_name': ha.VG, 'vg_uuid': ha.VG_UUID, 'vg_free': 2692 * ha.GIB}],
            'lvs': [{'lv_name': 'ubuntu-lv', 'lv_uuid': ha.ROOT_UUID, 'vg_name': ha.VG,
                     'lv_size': 100 * ha.GIB, 'segtype': 'linear', 'devices': '/dev/sdz3(0)', 'lv_attr': '-wi-ao----'}]}


class Safety(unittest.TestCase):
    def validate(self, data, serial=ha.SERIAL):
        return ha.validate(data, serial, f'/dev/{ha.VG}/ubuntu-lv')

    def test_disk_letters_change(self):
        self.assertEqual(self.validate(fixture()), 2692 * ha.GIB)

    def test_identities_membership_types(self):
        changes = [lambda d: d.update(host='wrong'),
                   lambda d: d['vgs'][0].update(vg_uuid='wrong'),
                   lambda d: d['pvs'][0].update(pv_uuid='wrong'),
                   lambda d: d['pvs'].append(copy.deepcopy(d['pvs'][0])),
                   lambda d: d['lvs'][0].update(lv_uuid='wrong'),
                   lambda d: d['lvs'][0].update(lv_size=101 * ha.GIB),
                   lambda d: d['lvs'][0].update(devices='/dev/sda1(0)'),
                   lambda d: d['lvs'][0].update(segtype='thin'),
                   lambda d: d.update(pv_path=f'/dev/{ha.VG}/ubuntu-lv')]
        for change in changes:
            with self.subTest(change=change):
                data = fixture()
                change(data)
                with self.assertRaises(RuntimeError):
                    self.validate(data)
        with self.assertRaises(RuntimeError):
            self.validate(fixture(), 'Z4Y1FGA3')

    def test_capacity(self):
        ha.capacity(868 * ha.GIB, 356)
        with self.assertRaises(RuntimeError):
            ha.capacity(867 * ha.GIB, 356)
        with self.assertRaises(RuntimeError):
            ha.capacity(900 * ha.GIB, -1)

    def test_manually_created_layout(self):
        data = fixture()
        data['lvs'].append(dict(data['lvs'][0], lv_name='drbd-nfs', lv_uuid='new'))
        self.assertEqual(list(ha.allocation(data)), ['nfs'])
        data['lvs'][-1]['lv_size'] = 99 * ha.GIB
        with self.assertRaises(RuntimeError):
            ha.allocation(data)

    def test_policy_restored_on_failure_success_and_symlink(self):
        for existing in ('absent', 'file', 'symlink'):
            for fail in (False, True):
                with self.subTest(existing=existing, fail=fail), tempfile.TemporaryDirectory() as temp:
                    policy = Path(temp) / 'policy-rc.d'
                    target = Path(temp) / 'original'
                    target.write_text('original policy\n')
                    if existing == 'file':
                        policy.write_text('original policy\n')
                        policy.chmod(0o751)
                    elif existing == 'symlink':
                        policy.symlink_to(target)
                    previous = policy.lstat() if policy.is_symlink() or policy.exists() else None
                    try:
                        with ha.suppress_starts(policy):
                            self.assertIn('exit 101', policy.read_text())
                            if fail:
                                raise RuntimeError('apt failed')
                    except RuntimeError:
                        pass
                    if previous:
                        self.assertEqual(policy.lstat().st_ino, previous.st_ino)
                        self.assertEqual(policy.lstat().st_mode, previous.st_mode)
                        self.assertEqual(policy.read_text(), 'original policy\n')
                    else:
                        self.assertFalse(policy.exists())

    def test_simulation(self):
        ha.check_simulation('0 upgraded, 81 newly installed, 0 to remove and 0 not upgraded.\n')
        for output in ('1 upgraded, 81 newly installed, 0 to remove', '0 upgraded, 1 newly installed, 1 to remove',
                       '0 upgraded, 1 newly installed, 0 to remove\nInst linux-image-test (1)',
                       '0 upgraded, 1 newly installed, 0 to remove\nInst lvm2 [1] (2)'):
            with self.assertRaises(RuntimeError):
                ha.check_simulation(output)

    def test_package_failure_restores_policy(self):
        from subprocess import CompletedProcess
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            policy = state / 'policy-rc.d'
            policy.write_text('original')
            policy.chmod(0o751)
            original = ha.suppress_starts
            def command(args, **kwargs):
                if args[0] == 'apt-get' and '--assume-yes' in args:
                    self.assertIn('exit 101', policy.read_text())
                    self.assertEqual(kwargs['env']['NEEDRESTART_SUSPEND'], '1')
                    raise RuntimeError('injected installation failure')
                output = '0 upgraded, 81 newly installed, 0 to remove' if '-s' in args else ''
                return CompletedProcess(args, 0, output, '')
            with patch.object(ha, 'STATE', state), patch.object(ha, 'checked'), patch.object(ha, 'inactive'), patch.object(ha, 'health', return_value={}), patch.object(ha, 'check_health'), patch.object(ha, 'suppress_starts', side_effect=lambda: original(policy)), patch.object(ha, 'run', side_effect=command):
                with self.assertRaisesRegex(RuntimeError, 'injected installation failure'):
                    ha.packages(True)
            self.assertEqual(policy.read_text(), 'original')
            self.assertEqual(policy.stat().st_mode & 0o777, 0o751)
            self.assertEqual(len(list(state.glob('packages-after-*.json'))), 1)

    def test_unexpected_lv(self):
        data = fixture()
        data['lvs'].append(dict(data['lvs'][0], lv_name='unexpected'))
        with self.assertRaises(RuntimeError):
            self.validate(data)

    def test_stage_cannot_activate(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(ha, 'checked', return_value=(fixture(), 2692 * ha.GIB)), patch.object(ha, 'run') as command:
            ha.config(Namespace(output=str(Path(temp) / 'stage')))
            document = json.loads((Path(temp) / 'stage/preparation.json').read_text())
            self.assertFalse(document['activation_allowed'])
            self.assertEqual(len(document['unresolved']), 6)
            command.assert_not_called()


if __name__ == '__main__':
    unittest.main()
