#!/usr/bin/env python3
"""Explicit Pacemaker-only cutover actions. Defaults to printing a plan."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import xml.etree.ElementTree as E
from nfs_ha_phase import phase, normalized

HOSTS = ('ubuntu-master2.koeppster.lan', 'ubuntu-slave1.koeppster.lan')
PRIMARY = HOSTS[0]
CLONES = ['cl-drbd-'+r for r in ('kube', 'grafana', 'postgres', 'nfs-state')]
GATES = ('vip_reserved_and_reachable', 'fsids_clients_options_verified',
         'partition_quorum_tested', 'drbd_peer_fencing_reviewed', 'both_hosts_ready',
         'post_maintenance_links_and_drbd_verified', 'quorum_loss_outage_accepted',
         'units_reviewed', 'simulation_reviewed',
         'master2_nfs_handoff_complete',
         'migration_no_failover_accepted', 'ha_writers_stopped')
RETIREMENT_GATES = ('legacy_consumers_absent', 'legacy_exports_absent',
                    'legacy_service_disabled', 'legacy_mounts_absent',
                    'legacy_boot_mounts_removed')


def required_gates(mode, record, action):
    if mode != 'migration':
        raise ValueError('Only master2-only migration is supported')
    # Older migration records remain valid only under the preserved-service gate.
    state = record.get('legacy_service_state', 'preserved')
    if state == 'preserved':
        if any(record.get(g) is True for g in RETIREMENT_GATES):
            raise ValueError('Preserved legacy service conflicts with retirement assertions')
        return GATES + ('legacy_service_preserved',)
    if state != 'retired':
        raise ValueError('legacy_service_state must be preserved or retired')
    if action == 'submit':
        raise ValueError('Retired legacy service is supported only for stop/activate, not submit')
    if record.get('legacy_service_preserved') is not False:
        raise ValueError('Retired legacy service requires legacy_service_preserved=false')
    evidence = record.get('legacy_retirement_evidence')
    if not isinstance(evidence, str) or not evidence.strip():
        raise ValueError('Retired legacy service requires legacy_retirement_evidence')
    return GATES + RETIREMENT_GATES



def run(args):
    return subprocess.check_output(args, text=True)


def require_live_two_vote_quorum(status):
    fields = {name.strip(): value.strip() for name, value in
              re.findall(r'^\s*([^:\n]+):\s*([^\n]+)$', status, re.MULTILINE)}
    expected = {'Quorate': 'Yes', 'Nodes': '2', 'Expected votes': '2',
                'Total votes': '2', 'Quorum': '2'}
    if any(fields.get(name) != value for name, value in expected.items()):
        raise ValueError('Both votes and quorum of two are required before submit/activate')


def validate(root):
    mode = phase(root)
    props = {x.get('name'): x.get('value') for x in root.findall('./configuration/crm_config//nvpair')}
    if any(props.get(k) != v for k, v in {'stonith-enabled': 'false', 'startup-fencing': 'false',
            'no-quorum-policy': 'stop', 'cluster-name': 'nfs-ha'}.items()):
        raise ValueError('Required cluster safety properties do not match')
    if props.get('maintenance-mode', 'false') != 'false' or props.get('stop-all-resources', 'false') != 'false':
        raise ValueError('Cluster is in maintenance/stop-all mode')
    if root.findall('./configuration/resources/primitive[@class="stonith"]'):
        raise ValueError('This master2-only stage must not include node fencing resources')
    cfg = root.find('configuration')
    if {n.get('uname') for n in cfg.findall('./nodes/node')} != set(HOSTS):
        raise ValueError('Unexpected cluster membership')
    if any(x.get('name', '').startswith('master-p-drbd-') for x in cfg.findall('.//nvpair')):
        raise ValueError('Synthetic promotion scores must never enter the live CIB')
    group = cfg.find('./resources/group[@id="g-nfs-ha"]')
    if group is None or [x.get('id') for x in group.findall('primitive')] != [
            'p-fs-nfs-state', 'p-fs-kube', 'p-fs-grafana', 'p-fs-postgres', 'p-nfs-server',
            'p-export-kube-1', 'p-export-kube-2', 'p-export-grafana-1', 'p-export-grafana-2',
            'p-export-postgres-1', 'p-export-postgres-2', 'p-nfs-vip']:
        raise ValueError('Service group differs from the verified six-export design')
    nfs = group.find('./primitive[@id="p-nfs-server"]')
    nfs_params = {x.get('name'): x.get('value') for x in
                  nfs.findall('./instance_attributes/nvpair')} if nfs is not None else {}
    if nfs_params.get('nfs_init_script') != '/usr/local/sbin/nfs-ha-nfsserver-control' or nfs_params.get('nfsv4_only') != 'true':
        raise ValueError('NFS server must use the reviewed systemd control wrapper in NFSv4-only mode')
    for resource in ('kube', 'grafana', 'postgres', 'nfs-state'):
        clone = cfg.find(f'./resources/clone[@id="cl-drbd-{resource}"]')
        if clone is None:
            raise ValueError('Missing DRBD clone')
        meta = {x.get('name'): x.get('value') for x in clone.findall('./meta_attributes/nvpair')}
        if any(meta.get(k) != v for k, v in {'promotable': 'true', 'promoted-max': '1',
                'promoted-node-max': '1', 'clone-max': '2', 'clone-node-max': '1'}.items()):
            raise ValueError('Unsafe DRBD clone limits')
        order = cfg.find(f'./constraints/rsc_order[@id="order-{resource}"]')
        col = cfg.find(f'./constraints/rsc_colocation[@id="col-{resource}"]')
        if order is None or any(order.get(k) != v for k, v in {
                'first': 'cl-drbd-'+resource, 'first-action': 'promote', 'then': 'g-nfs-ha',
                'then-action': 'start', 'kind': 'Mandatory', 'symmetrical': 'true'}.items()):
            raise ValueError('Missing promotion ordering')
        if col is None or any(col.get(k) != v for k, v in {
                'rsc': 'g-nfs-ha', 'with-rsc': 'cl-drbd-'+resource,
                'with-rsc-role': 'Promoted', 'score': 'INFINITY'}.items()):
            raise ValueError('Missing promoted-role colocation')
    for ident in ['g-nfs-ha', *CLONES]:
        if cfg.find(f"./resources/*[@id='{ident}']") is None:
            raise ValueError(f'Missing {ident}')


    return mode


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['submit', 'activate', 'stop'])
    p.add_argument('--stage', type=Path, required=True)
    p.add_argument('--record', type=Path, help='Private reviewed maintenance JSON; required to execute')
    p.add_argument('--execute', action='store_true')
    a = p.parse_args()
    stage = a.stage.resolve()
    candidate = stage/'cib-stopped.xml'
    commands = {
        'submit': [['pcs', 'cluster', 'cib-push', str(candidate), '--config']],
        'activate': [['pcs', 'resource', 'enable', *CLONES, 'g-nfs-ha', '--wait=1800']],
        'stop': [['pcs', 'resource', 'disable', 'g-nfs-ha', '--wait=1800'],
                 ['pcs', 'resource', 'disable', *CLONES, '--wait=600']],
    }[a.action]
    if not a.execute:
        print('PLAN ONLY. Execution requires the phase-specific maintenance record.')
        for cmd in commands:
            print(shlex.join(cmd))
        return
    if os.geteuid() != 0 or not a.record:
        raise ValueError('Execution requires root and --record')
    if run(['hostname', '-f']).strip() != PRIMARY:
        raise ValueError('Run cutover commands on master2')
    record = json.loads(a.record.read_text())
    approved = datetime.fromisoformat(record['reviewed_at'])
    age = (datetime.now(timezone.utc) - approved).total_seconds()
    if not 0 <= age <= 14400:
        raise ValueError('Maintenance review must be within the last four hours')
    if record.get('cib_sha256') != hashlib.sha256(candidate.read_bytes()).hexdigest():
        raise ValueError('Maintenance record does not match the reviewed candidate')
    planned = E.parse(candidate).getroot()
    mode = phase(planned)
    gates = required_gates(mode, record, a.action)
    if any(record.get(g) is not True for g in gates):
        raise ValueError('Unresolved maintenance gates: '+', '.join(g for g in gates if record.get(g) is not True))
    validate(planned)
    subprocess.run(['crm_verify', '--xml-file', str(candidate)], check=True)
    if a.action in ('submit', 'activate'):
        require_live_two_vote_quorum(run(['corosync-quorumtool', '-s']))
    live = E.fromstring(run(['cibadmin', '--query']))
    backup = stage / ('live-before-'+a.action+'-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f')+'.xml')
    os.umask(0o077)
    E.ElementTree(live).write(backup)
    if a.action == 'submit':
        # Submission is only to a bootstrapped, empty application cluster.
        existing = live.findall('./configuration/resources/*')
        if existing or live.findall('./configuration/constraints/*'):
            raise ValueError('Live cluster must have no application or fencing resources or constraints')
        if {n.get('uname') for n in live.findall('./configuration/nodes/node')} != set(HOSTS):
            raise ValueError('Live node names differ from the reviewed stage')
        if any(x.get('value') != 'Stopped' for x in planned.findall('.//nvpair[@name="target-role"]')):
            raise ValueError('Submit only the stopped candidate')
        if len(planned.findall('.//nvpair[@name="target-role"]')) != 5:
            raise ValueError('All four clones and the group must be stopped')
    else:
        live_mode = validate(live)
        if live_mode != mode:
            raise ValueError('Live and staged phases differ')
    if a.action == 'activate':
        # Exact config comparison prevents activation of a stale or modified CIB.
        if normalized(live) != normalized(planned):
            raise ValueError('Live config differs from staged stopped config; inspect before activation')
    for cmd in commands:
        subprocess.run(cmd, check=True)
    print(run(['pcs', 'status', '--full']))
    print('Check both hosts, VIP, mounts, exports and client I/O using the runbook. No automatic rollback.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
