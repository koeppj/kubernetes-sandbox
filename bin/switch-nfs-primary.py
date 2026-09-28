#!/usr/bin/env python3
"""Controlled, two-node Pacemaker handoff of the NFS/DRBD service."""

import argparse
import copy
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET


HOSTS = ('ubuntu-master2.koeppster.lan', 'ubuntu-slave1.koeppster.lan')
RESOURCES = ('kube', 'grafana', 'postgres', 'nfs-state')
GROUP = ('p-fs-nfs-state', 'p-fs-kube', 'p-fs-grafana', 'p-fs-postgres',
         'p-nfs-server', 'p-export-kube-1', 'p-export-kube-2',
         'p-export-grafana-1', 'p-export-grafana-2',
         'p-export-postgres-1', 'p-export-postgres-2', 'p-nfs-vip')
MOUNTS = ('/var/lib/nfs-ha', '/srv/ha/kube-lv', '/srv/ha/kube-grafana',
          '/srv/ha/kube-postgres')
VIP = '192.168.1.240'
DEMO_PREFERENCE = 'demo-prefer-nfs-owner'


def command(args, *, privileged=False, remote=None):
    if remote:
        args = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', remote,
                *(['sudo', '-n'] if privileged else []), *args]
    elif privileged and os.geteuid() != 0:
        args = ['sudo', '-n', *args]
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout


def xml_command(args, **kwargs):
    return ET.fromstring(command(args, **kwargs))


def owner(root):
    locations = root.findall('./configuration/constraints/rsc_location')
    demo = [x for x in locations if x.get('id') == DEMO_PREFERENCE]
    found = {x.get('id'): x for x in locations if x.get('id', '').startswith('migration-')}
    if demo:
        expected_demo = {'id': DEMO_PREFERENCE, 'rsc': 'g-nfs-ha',
                         'node': demo[0].get('node'), 'score': '100000'}
        if (found or len(demo) != 1 or dict(demo[0].attrib) != expected_demo or
                demo[0].get('node') not in HOSTS or len(demo[0])):
            raise ValueError('Demo preference is invalid or mixed with migration bans')
        return demo[0].get('node')
    expected = {'migration-service-ban': ('g-nfs-ha', None)}
    expected.update({'migration-promote-ban-' + r: ('cl-drbd-' + r, 'Promoted')
                     for r in RESOURCES})
    if set(found) != set(expected):
        raise ValueError('The five migration placement restrictions differ from the reviewed layout')
    banned = set()
    for ident, (resource, role) in expected.items():
        attrs = {'id': ident, 'rsc': resource, 'score': '-INFINITY'}
        if role:
            attrs['role'] = role
        else:
            attrs['resource-discovery'] = 'never'
        item = found[ident]
        if item.tag != 'rsc_location' or len(item) or any(item.get(k) != v for k, v in attrs.items()) or set(item.attrib) != set(attrs) | {'node'}:
            raise ValueError('Unexpected placement restriction: ' + ident)
        banned.add(item.get('node'))
    if len(banned) != 1 or not banned.issubset(HOSTS):
        raise ValueError('The five restrictions must ban the same known host')
    return next(h for h in HOSTS if h not in banned)


def validate_configuration(root):
    props = {x.get('name'): x.get('value') for x in root.findall('./configuration/crm_config//nvpair')}
    preferred = owner(root)
    demo = root.find(f'./configuration/constraints/rsc_location[@id="{DEMO_PREFERENCE}"]') is not None
    for key, value in {'cluster-name': 'nfs-ha', 'no-quorum-policy': 'ignore' if demo else 'stop',
                       'stonith-enabled': 'false', 'startup-fencing': 'false'}.items():
        if props.get(key) != value:
            raise ValueError('Unexpected Pacemaker property: ' + key)
    if props.get('maintenance-mode', 'false') != 'false' or props.get('stop-all-resources', 'false') != 'false':
        raise ValueError('Cluster maintenance or stop-all mode is active')
    if {n.get('uname') for n in root.findall('./configuration/nodes/node')} != set(HOSTS):
        raise ValueError('Unexpected cluster membership')
    group = root.find('./configuration/resources/group[@id="g-nfs-ha"]')
    if group is None or tuple(n.get('id') for n in group.findall('primitive')) != GROUP:
        raise ValueError('NFS group does not match the reviewed layout')
    for resource in RESOURCES:
        clone = root.find(f'./configuration/resources/clone[@id="cl-drbd-{resource}"]')
        if clone is None:
            raise ValueError('Missing DRBD clone: ' + resource)
        meta = {n.get('name'): n.get('value') for n in clone.findall('./meta_attributes/nvpair')}
        if any(meta.get(k) != v for k, v in {'promotable': 'true', 'promoted-max': '1',
                'promoted-node-max': '1', 'clone-max': '2', 'clone-node-max': '1'}.items()):
            raise ValueError('Unsafe DRBD clone limits: ' + resource)
        col = root.find(f'./configuration/constraints/rsc_colocation[@id="col-{resource}"]')
        order = root.find(f'./configuration/constraints/rsc_order[@id="order-{resource}"]')
        if col is None or any(col.get(k) != v for k, v in {'rsc': 'g-nfs-ha',
                'with-rsc': 'cl-drbd-' + resource, 'with-rsc-role': 'Promoted',
                'score': 'INFINITY'}.items()):
            raise ValueError('Missing promoted colocation: ' + resource)
        if order is None or any(order.get(k) != v for k, v in {'first': 'cl-drbd-' + resource,
                'first-action': 'promote', 'then': 'g-nfs-ha', 'then-action': 'start',
                'kind': 'Mandatory', 'symmetrical': 'true'}.items()):
            raise ValueError('Missing promotion ordering: ' + resource)
    return preferred


def active_nodes(resource):
    return [(n.get('name'), resource.get('role')) for n in resource.findall('node')]


def validate_runtime(status, current):
    dc = status.find('./summary/current_dc')
    if dc is None or dc.get('with_quorum') != 'true':
        raise ValueError('Cluster has no quorum')
    nodes = status.findall('./nodes/node')
    if {n.get('name') for n in nodes} != set(HOSTS) or any(
            n.get('online') != 'true' or n.get('standby') != 'false' or
            n.get('unclean') != 'false' or n.get('maintenance') != 'false' for n in nodes):
        raise ValueError('Both hosts must be healthy, online, and out of standby')
    opts = status.find('./summary/cluster_options')
    if opts is None or opts.get('maintenance-mode') != 'false' or opts.get('stop-all-resources') != 'false':
        raise ValueError('Cluster is in maintenance or stop-all mode')
    for resource in RESOURCES:
        clone = status.find(f'./resources/clone[@id="cl-drbd-{resource}"]')
        if clone is None or clone.get('failed') != 'false' or clone.get('disabled') != 'false':
            raise ValueError('DRBD clone is failed or disabled: ' + resource)
        roles = []
        for member in clone.findall('resource'):
            if member.get('active') != 'true' or member.get('failed') != 'false':
                raise ValueError('DRBD member is not healthy: ' + resource)
            roles.extend(active_nodes(member))
        if set(roles) != {(current, 'Promoted'), (next(h for h in HOSTS if h != current), 'Unpromoted')}:
            raise ValueError('Unexpected DRBD roles for ' + resource)
    group = status.find('./resources/group[@id="g-nfs-ha"]')
    if group is None or group.get('disabled') != 'false' or tuple(r.get('id') for r in group.findall('resource')) != GROUP:
        raise ValueError('NFS group is missing, disabled, or changed')
    for resource in group.findall('resource'):
        if resource.get('active') != 'true' or resource.get('failed') != 'false' or active_nodes(resource) != [(current, 'Started')]:
            raise ValueError('NFS group is not fully running on ' + current)
def require_replication(host, expected_role, *, remote=False):
    for resource in RESOURCES:
        kwargs = {'remote': host} if remote else {}
        role = command(['drbdadm', 'role', resource], privileged=True, **kwargs).strip()
        disks = command(['drbdadm', 'dstate', resource], privileged=True, **kwargs).strip()
        link = command(['drbdadm', 'cstate', resource], privileged=True, **kwargs).strip()
        if role != expected_role or disks != 'UpToDate/UpToDate' or link != 'Connected':
            raise ValueError(f'{host} {resource}: role={role}, disks={disks}, link={link}; handoff requires synchronized replicas')


def check_target(host):
    if command(['hostname', '-f'], remote=host).strip() != host:
        raise ValueError('SSH target hostname does not match ' + host)
    require_replication(host, 'Secondary/Primary', remote=True)
    # is-active exits nonzero when inactive; inspect its output without check=True.
    probe = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', host,
                            'systemctl', 'is-active', 'nfs-server.service'],
                           text=True, capture_output=True)
    if probe.stdout.strip() != 'inactive' or probe.returncode not in (0, 3):
        raise ValueError('Target independent NFS service is not confirmed inactive')
    for mount in MOUNTS:
        result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', host,
                                 'findmnt', '-rn', '-M', mount], text=True, capture_output=True)
        if result.returncode != 1:
            raise ValueError('Target HA mount is present or mount check failed: ' + mount)
    addresses = command(['ip', '-o', '-4', 'addr', 'show'], remote=host)
    if re.search(r'\binet\s+' + re.escape(VIP) + r'/', addresses):
        raise ValueError('VIP is already present on target before handoff')


def make_candidate(root, target):
    candidate = copy.deepcopy(root)
    demo = candidate.find(f'./configuration/constraints/rsc_location[@id="{DEMO_PREFERENCE}"]')
    if demo is not None:
        demo.set('node', target)
        return candidate
    banned = next(h for h in HOSTS if h != target)
    for item in candidate.findall('./configuration/constraints/rsc_location'):
        if item.get('id', '').startswith('migration-'):
            item.set('node', banned)
    return candidate


def verify_arrival(target, deadline):
    while time.monotonic() < deadline:
        try:
            root = xml_command(['cibadmin', '--query'], privileged=True)
            status = xml_command(['crm_mon', '--one-shot', '--output-as=xml'], privileged=True)
            if validate_configuration(root) == target:
                validate_runtime(status, target)
                require_replication(target, 'Primary/Secondary', remote=True)
                require_replication(next(h for h in HOSTS if h != target), 'Secondary/Primary')
                for mount in MOUNTS:
                    command(['findmnt', '-rn', '-M', mount], remote=target)
                    absent = subprocess.run(['findmnt', '-rn', '-M', mount],
                                            text=True, capture_output=True)
                    if absent.returncode != 1:
                        raise ValueError('Old owner still has an HA mount: ' + mount)
                target_ip = command(['ip', '-o', '-4', 'addr', 'show'], remote=target)
                source_ip = command(['ip', '-o', '-4', 'addr', 'show'])
                pattern = r'\binet\s+' + re.escape(VIP) + r'/'
                if not re.search(pattern, target_ip) or re.search(pattern, source_ip):
                    raise ValueError('VIP is absent from target or present on old owner')
                return
        except (ValueError, subprocess.CalledProcessError):
            pass
        time.sleep(5)
    raise ValueError('Handoff did not become healthy before timeout; inspect pcs status --full and DRBD on both hosts')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--to', choices=HOSTS, required=True, help='New primary and NFS owner')
    parser.add_argument('--execute', action='store_true', help='Apply the reviewed placement change')
    parser.add_argument('--writers-stopped', action='store_true', help='Attest all NFS writers are stopped')
    parser.add_argument('--timeout', type=int, default=900, help='Seconds to wait for complete handoff (default: 900)')
    args = parser.parse_args()
    if args.timeout < 120:
        parser.error('--timeout must be at least 120 seconds')
    if args.execute and not args.writers_stopped:
        parser.error('--execute requires --writers-stopped')
    if os.geteuid() == 0:
        parser.error('Run as a regular SSH user with passwordless sudo for cluster commands')
    root = xml_command(['cibadmin', '--query'], privileged=True)
    preferred = validate_configuration(root)
    demo = root.find(f'./configuration/constraints/rsc_location[@id="{DEMO_PREFERENCE}"]') is not None
    status = xml_command(['crm_mon', '--one-shot', '--output-as=xml'], privileged=True)
    vip_node = status.find('./resources/group[@id="g-nfs-ha"]/resource[@id="p-nfs-vip"]/node')
    if vip_node is None or vip_node.get('name') not in HOSTS:
        raise ValueError('Cannot identify the current NFS owner')
    current = vip_node.get('name')
    if command(['hostname', '-f']).strip() != current:
        raise ValueError('Run this script on the current NFS owner: ' + current)
    if current == args.to:
        raise ValueError('The service is already assigned to ' + current)
    if preferred != current and not demo:
        raise ValueError('Configured preferred owner differs from current owner; resolve before handoff')
    validate_runtime(status, current)
    quorum = command(['corosync-quorumtool', '-s'], privileged=True)
    for field in ('Nodes', 'Expected votes', 'Total votes', 'Quorum'):
        if not re.search(r'^' + re.escape(field) + r':\s+2\s*$', quorum, re.MULTILINE):
            raise ValueError('Expected two-vote quorum is not intact')
    require_replication(current, 'Primary/Secondary')
    addresses = command(['ip', '-o', '-4', 'addr', 'show'])
    if not re.search(r'\binet\s+' + re.escape(VIP) + r'/', addresses):
        raise ValueError('VIP is absent from current NFS owner')
    check_target(args.to)
    candidate = make_candidate(root, args.to)
    with tempfile.TemporaryDirectory(prefix='nfs-ha-handoff-') as directory:
        path = Path(directory)
        path.chmod(0o700)
        cib = path / 'candidate.xml'
        constraints = path / 'constraints.xml'
        ET.ElementTree(candidate).write(cib, encoding='unicode', xml_declaration=True)
        ET.ElementTree(candidate.find('./configuration/constraints')).write(
            constraints, encoding='unicode', xml_declaration=True)
        command(['crm_verify', '-x', str(cib), '-V'], privileged=True)
        simulation = command(['crm_simulate', '-S', '-x', str(cib)], privileged=True)
        if not re.search(r'^\s*\* Resource action:\s+p-nfs-vip\s+start on ' +
                         re.escape(args.to) + r'\s*$', simulation, re.MULTILINE):
            raise ValueError('Simulation did not show VIP starting on the target')
        print(f'Validated handoff: {current} -> {args.to}')
        print('Pacemaker will stop the NFS group, demote four DRBD resources, then start on the target.')
        if demo:
            print('Demo mode permits one-host operation; an isolated peer cannot be fenced.')
        else:
            print('Two votes remain required: NFS stops if either host leaves Corosync.')
        if not args.execute:
            print('Preview only. Stop Kubernetes workloads and other NFS writers, then rerun with --execute --writers-stopped.')
            return
        latest = xml_command(['cibadmin', '--query'], privileged=True)
        if ET.tostring(latest.find('configuration')) != ET.tostring(root.find('configuration')):
            raise ValueError('Cluster configuration changed during preflight; rerun the preview')
        command(['cibadmin', '--replace', '--scope', 'constraints', '--xml-file', str(constraints)], privileged=True)
        print('Placement restrictions changed; waiting for all resources on ' + args.to, flush=True)
        verify_arrival(args.to, time.monotonic() + args.timeout)
        print('Handoff complete: all four DRBD primaries and the NFS group are on ' + args.to)
        if not demo:
            print('Keep both Corosync votes online; taking either host offline still stops this service.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, ET.ParseError, subprocess.CalledProcessError, OSError) as exc:
        print(f'Handoff stopped: {exc}', file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            print(exc.stderr.strip(), file=sys.stderr)
        sys.exit(1)
