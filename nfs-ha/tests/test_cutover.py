"""Offline safety and dependency checks; no live CIB, mounts, or fencing calls."""
import importlib.util
import hashlib
import json
from datetime import datetime, timezone
import os
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as E
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


render = module('render', 'nfs-ha-render.py')
cutover = module('cutover', 'nfs-ha-cutover.py')
ENV = dict(NFS_HA_PHASE='migration', NFS_HA_VIP='192.168.1.240', NFS_HA_PREFIX='24', NFS_HA_INTERFACE='enp2s0',
           NFS_HA_SCOPE='192.168.1.240', NFS_HA_CLIENTS='192.168.1.0/24 10.0.0.0/24',
           NFS_HA_FSID_KUBE='102', NFS_HA_FSID_GRAFANA='103', NFS_HA_FSID_POSTGRES='104',
           NFS_HA_EXPORT_STOP_TIMEOUT='180')


class Cutover(unittest.TestCase):
    def test_live_quorum_guard_rejects_one_vote_mode(self):
        status = 'Nodes: 2\nQuorate: Yes\nExpected votes: 2\nTotal votes: 2\nQuorum: 2\n'
        cutover.require_live_two_vote_quorum(status)
        with self.assertRaisesRegex(ValueError, 'quorum of two'):
            cutover.require_live_two_vote_quorum(status.replace('Quorum: 2', 'Quorum: 1'))
        with self.assertRaisesRegex(ValueError, 'quorum of two'):
            cutover.require_live_two_vote_quorum(status.replace('Nodes: 2', 'Nodes: 1'))

    def test_reject_invalid_network_and_ids(self):
        for key, value in [('NFS_HA_VIP', ''), ('NFS_HA_VIP', '192.168.1.235'),
                           ('NFS_HA_VIP', '192.168.1.250'), ('NFS_HA_VIP', '10.0.0.4'),
                           ('NFS_HA_FSID_KUBE', '103'), ('NFS_HA_SCOPE', ''),
                           ('NFS_HA_EXPORT_STOP_TIMEOUT', '90'), ('NFS_HA_PHASE', 'ha')]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                render.render({**ENV, key: value})

    def test_dependency_graph_and_exports(self):
        root = render.render(ENV)
        clones = root.findall('./configuration/resources/clone')
        self.assertEqual(len(clones), 4)
        self.assertEqual(len(root.findall('.//nvpair[@name="target-role"][@value="Stopped"]')), 5)
        group = root.find('./configuration/resources/group')
        ids = [p.get('id') for p in group.findall('primitive')]
        self.assertEqual(ids[:4], ['p-fs-nfs-state', 'p-fs-kube', 'p-fs-grafana', 'p-fs-postgres'])
        self.assertEqual(ids[4], 'p-nfs-server')
        self.assertEqual(ids[-1], 'p-nfs-vip')
        exports = group.findall('primitive[@type="exportfs"]')
        self.assertEqual(len(exports), 6)
        for p in exports:
            params = {x.get('name'): x.get('value') for x in p.findall('./instance_attributes/nvpair')}
            self.assertNotIn('/var/lib/nfs-ha', params['directory'])
            self.assertIn('root_squash', params['options'])
            self.assertEqual(params['unlock_on_stop'], '0')
            self.assertEqual(params['wait_for_leasetime_on_stop'], '1')
        constraints = root.find('./configuration/constraints')
        self.assertEqual(len(constraints.findall('rsc_colocation')), 4)
        self.assertEqual(len(constraints.findall('rsc_order')), 4)
        for c in constraints.findall('rsc_order'):
            self.assertEqual(c.get('first-action'), 'promote')
            self.assertEqual(c.get('then'), 'g-nfs-ha')
        self.assertEqual(cutover.validate(root), 'migration')
        props = {x.get('name'): x.get('value') for x in root.findall('./configuration/crm_config//nvpair')}
        self.assertEqual(props['stonith-enabled'], 'false')
        self.assertEqual(props['no-quorum-policy'], 'stop')
        constraints.remove(constraints.find('rsc_location[@id="migration-service-ban"]'))
        with self.assertRaisesRegex(ValueError, 'Incomplete migration'):
            cutover.validate(root)

    def test_dry_run_never_queries_or_changes_cluster(self):
        with patch('sys.argv', ['cutover', 'activate', '--stage', '/nonexistent']), patch.object(subprocess, 'run') as run, patch.object(subprocess, 'check_output') as query:
            cutover.main()
            run.assert_not_called()
            query.assert_not_called()

    def test_unresolved_record_blocks_before_live_query_or_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp)
            candidate = stage/'cib-stopped.xml'
            render.write(render.render(ENV), candidate)
            record = stage/'record.json'
            record.write_text(json.dumps({
                'reviewed_at': datetime.now(timezone.utc).isoformat(),
                'cib_sha256': hashlib.sha256(candidate.read_bytes()).hexdigest(),
                **{g: False for g in cutover.GATES}}))
            argv = ['cutover', 'submit', '--stage', str(stage), '--record', str(record), '--execute']
            with patch('sys.argv', argv), patch.object(os, 'geteuid', return_value=0), patch.object(cutover, 'run', return_value=cutover.HOSTS[0]) as query, patch.object(subprocess, 'run') as command:
                with self.assertRaisesRegex(ValueError, 'Unresolved maintenance gates'):
                    cutover.main()
                query.assert_called_once_with(['hostname', '-f'])
                command.assert_not_called()

    def test_base_cannot_smuggle_non_fencing_workloads(self):
        with self.assertRaisesRegex(ValueError, 'fencing base is not used'):
            render.render(ENV, render.render(ENV))

    def test_stack_plan_preserves_binding_and_rejects_unsafe_source(self):
        planner = module('planner', 'nfs-ha-stack-plan.py')
        pvc = {'metadata': {'namespace': 'test', 'name': 'data', 'uid': 'old-uid'},
               'spec': {'volumeName': 'old-pv', 'storageClassName': 'kube-nfs',
                        'accessModes': ['ReadWriteOnce'], 'resources': {'requests': {'storage': '1Gi'}}},
               'status': {'phase': 'Bound'}}
        pv = {'metadata': {'name': 'old-pv', 'uid': 'pv-uid'},
              'status': {'phase': 'Bound'}, 'spec': {
                  'claimRef': {'namespace': 'test', 'name': 'data', 'uid': 'old-uid'},
                  'persistentVolumeReclaimPolicy': 'Delete', 'storageClassName': 'kube-nfs',
                  'capacity': {'storage': '1Gi'}, 'accessModes': ['ReadWriteOnce'],
                  'mountOptions': ['hard', 'nfsvers=4.1'],
                  'csi': {'driver': 'nfs.csi.k8s.io', 'volumeHandle': 'old',
                          'volumeAttributes': {'server': '192.168.1.235', 'share': '/srv/kube-lv',
                                               'subdir': 'data-pvc', 'mountPermissions': '0777'}}}}
        newpv, newpvc, mapping = planner.rebind(pv, pvc, ENV['NFS_HA_VIP'])
        self.assertEqual(newpv['spec']['persistentVolumeReclaimPolicy'], 'Retain')
        self.assertEqual(newpv['spec']['csi']['volumeAttributes']['share'], '/srv/ha/kube-lv/data-pvc')
        self.assertEqual(newpv['spec']['csi']['volumeAttributes']['mountPermissions'], '0')
        self.assertEqual(newpvc['metadata']['name'], 'data')
        self.assertEqual(newpvc['spec']['volumeName'], newpv['metadata']['name'])
        self.assertNotIn('uid', newpv['spec']['claimRef'])
        self.assertNotIn('uid', newpvc['metadata'])
        self.assertEqual(mapping['source_path'], '/srv/kube-lv/data-pvc')
        self.assertEqual(pv['spec']['persistentVolumeReclaimPolicy'], 'Delete')
        for bad in ('../other', '/absolute', 'a/../b', 'a//b', ''):
            invalid = render.copy.deepcopy(pv)
            invalid['spec']['csi']['volumeAttributes']['subdir'] = bad
            with self.assertRaises(ValueError):
                planner.rebind(invalid, pvc, ENV['NFS_HA_VIP'])
        invalid = render.copy.deepcopy(pv)
        invalid['spec']['claimRef']['uid'] = 'stale'
        with self.assertRaisesRegex(ValueError, 'binding changed'):
            planner.rebind(invalid, pvc, ENV['NFS_HA_VIP'])

    def test_native_scheduler_requires_both_votes_and_stops_on_quorum_loss(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp)/'stage'
            result = subprocess.run([sys.executable, str(SCRIPTS/'nfs-ha-render.py'), str(stage)],
                                    env={**os.environ, **ENV}, capture_output=True, text=True)
            logs = '\n'.join(p.read_text() for p in stage.glob('*.log')) if stage.exists() else ''
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr + logs)
            self.assertIn('expected_votes: 2', (stage/'corosync.conf').read_text())
            self.assertIn('two_node: 0', (stage/'corosync.conf').read_text())
            self.assertRegex((stage/'both.log').read_text(),
                             r'Resource action: p-nfs-vip +start on ubuntu-master2')
            for scenario in ('master2-only', 'slave1-only'):
                log = (stage/f'{scenario}.log').read_text()
                self.assertNotRegex(log, r'Resource action: p-nfs-vip +(start|promote)')
            self.assertRegex((stage/'quorum-loss.log').read_text(),
                             r'Resource action: p-nfs-vip +stop on ubuntu-master2')
            production = E.parse(stage/'cib-stopped.xml').getroot()
            self.assertEqual(cutover.validate(production), 'migration')
            self.assertEqual(len(production.findall('.//nvpair[@name="target-role"][@value="Stopped"]')), 5)
            simulation = render.copy.deepcopy(production)
            render.add_simulation_scores(simulation)
            with self.assertRaisesRegex(ValueError, 'Synthetic promotion scores'):
                cutover.validate(simulation)
            restartstage = Path(tmp)/'restart'
            restart = subprocess.run([sys.executable, str(SCRIPTS/'nfs-ha-stage-finalize.py'),
                                      '--restart', str(stage/'cib-stopped.xml'), str(restartstage)],
                                     capture_output=True, text=True)
            self.assertEqual(restart.returncode, 0, restart.stdout + restart.stderr)
            self.assertEqual(cutover.normalized(E.parse(restartstage/'cib-stopped.xml').getroot()),
                             cutover.normalized(production))
            unsupported = subprocess.run([sys.executable, str(SCRIPTS/'nfs-ha-stage-finalize.py'),
                                          str(stage/'cib-stopped.xml'), str(Path(tmp)/'ha')],
                                         capture_output=True, text=True)
            self.assertNotEqual(unsupported.returncode, 0)

    def test_reject_fencing_or_removed_master2_restrictions(self):
        root = render.render(ENV)
        primitive = E.SubElement(root.find('./configuration/resources'), 'primitive',
                                 id='unexpected-fence', **{'class': 'stonith', 'type': 'external/ipmi'})
        with self.assertRaisesRegex(ValueError, 'must not include node fencing'):
            cutover.validate(root)
        root.find('./configuration/resources').remove(primitive)
        root.find('./configuration/constraints').remove(
            root.find('./configuration/constraints/rsc_location[@id="migration-service-ban"]'))
        with self.assertRaisesRegex(ValueError, 'Incomplete migration'):
            cutover.validate(root)


if __name__ == '__main__':
    unittest.main()
