#!/usr/bin/env python3
"""Offline CIB and Corosync candidate. Local agent metadata is authoritative."""
import copy
import ipaddress
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as E
from nfs_ha_phase import restrictions

HOSTS = ('ubuntu-master2.koeppster.lan', 'ubuntu-slave1.koeppster.lan')
LAYOUT = [('kube', 1, '/srv/ha/kube-lv'), ('grafana', 2, '/srv/ha/kube-grafana'),
          ('postgres', 3, '/srv/ha/kube-postgres'), ('nfs-state', 4, '/var/lib/nfs-ha')]


def attributes(parent, tag, ident, values):
    block = E.SubElement(parent, tag, id=ident)
    for name, value in values.items():
        E.SubElement(block, 'nvpair', id=f'{ident}-{name}', name=name, value=str(value))
    return block


def primitive(parent, ident, agent, params, stop='120s'):
    provider, kind = agent.split(':')
    path = Path('/usr/lib/ocf/resource.d') / provider / kind
    metadata = E.fromstring(subprocess.check_output(
        [str(path), 'meta-data'], env={**os.environ, 'OCF_ROOT': '/usr/lib/ocf'}))
    supported = {p.get('name') for p in metadata.findall('./parameters/parameter')}
    if set(params) - supported:
        raise ValueError(f'{agent}: unsupported parameters {set(params) - supported}')
    node = E.SubElement(parent, 'primitive', id=ident, **{'class': 'ocf', 'provider': provider, 'type': kind})
    attributes(node, 'instance_attributes', ident+'-params', params)
    ops = E.SubElement(node, 'operations')
    for action, timeout, interval in [('start', '120s', '0'), ('stop', stop, '0'), ('monitor', '30s', '20s')]:
        E.SubElement(ops, 'op', id=f'{ident}-{action}', name=action, timeout=timeout, interval=interval)
    return node


def render(env, base=None):
    phase = env.get('NFS_HA_PHASE', 'migration')
    if phase != 'migration':
        raise ValueError('Only master2-only migration is supported without node fencing')
    if base is not None:
        raise ValueError('Migration uses an empty application CIB; a fencing base is not used')
    vip = ipaddress.IPv4Address(env['NFS_HA_VIP'])
    if vip not in ipaddress.ip_network('192.168.1.0/24') or vip in map(ipaddress.ip_address,
            ['192.168.1.0', '192.168.1.255', '192.168.1.194', '192.168.1.235']):
        raise ValueError('VIP must be a distinct usable address on the verified LAN')
    if 243 <= int(str(vip).split('.')[-1]) <= 254:
        raise ValueError('VIP overlaps the observed MetalLB pool')
    if env['NFS_HA_PREFIX'] != '24' or env['NFS_HA_INTERFACE'] != 'enp2s0':
        raise ValueError('Interface/prefix differs from the verified two-host inventory')
    scope = env['NFS_HA_SCOPE']
    if not scope or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-' for c in scope):
        raise ValueError('Set a stable hostname-safe NFS scope')
    clients = env['NFS_HA_CLIENTS'].split()
    if not clients or len(set(clients)) != len(clients):
        raise ValueError('Provide unique reviewed client CIDRs')
    for client in clients:
        ipaddress.ip_network(client, strict=True)
    fsids = [int(env['NFS_HA_FSID_'+r.upper()]) for r, _, _ in LAYOUT[:3]]
    if len(set(fsids)) != 3 or min(fsids) <= 0:
        raise ValueError('Three distinct positive fsids are required')
    stop = int(env['NFS_HA_EXPORT_STOP_TIMEOUT'])
    if stop < 120:
        raise ValueError('Export stop timeout must be at least 120 seconds and exceed the live lease')
    root = E.Element('cib', {'crm_feature_set': '3.16.2', 'validate-with': 'pacemaker-3.9',
                           'epoch': '1', 'num_updates': '0', 'admin_epoch': '0', 'have-quorum': '1'})
    cfg = E.SubElement(root, 'configuration')
    E.SubElement(cfg, 'crm_config')
    nodes = E.SubElement(cfg, 'nodes')
    for i, host in enumerate(HOSTS, 1):
        E.SubElement(nodes, 'node', id=str(i), uname=host)
    E.SubElement(cfg, 'resources')
    E.SubElement(cfg, 'constraints')
    attributes(cfg.find('crm_config'), 'cluster_property_set', 'nfs-ha-properties', {
        'cluster-name': 'nfs-ha', 'stonith-enabled': 'false', 'startup-fencing': 'false',
        'no-quorum-policy': 'stop', 'symmetric-cluster': 'true'})
    defaults = E.SubElement(cfg, 'rsc_defaults')
    attributes(defaults, 'meta_attributes', 'nfs-ha-defaults', {'resource-stickiness': '200'})
    resources = cfg.find('resources')
    constraints = cfg.find('constraints')
    for resource, _, _ in LAYOUT:
        ident = 'cl-drbd-'+resource
        clone = E.SubElement(resources, 'clone', id=ident)
        attributes(clone, 'meta_attributes', ident+'-meta', {
            'promotable': 'true', 'promoted-max': '1', 'promoted-node-max': '1',
            'clone-max': '2', 'clone-node-max': '1', 'notify': 'true', 'interleave': 'true',
            'target-role': 'Stopped'})
        p = primitive(clone, 'p-drbd-'+resource, 'linbit:drbd', {'drbd_resource': resource})
        ops = p.find('operations')
        ops.remove(ops.find("op[@name='monitor']"))
        for role, interval in [('Promoted', '15s'), ('Unpromoted', '30s')]:
            E.SubElement(ops, 'op', id=f'p-drbd-{resource}-{role}', name='monitor', role=role,
                         interval=interval, timeout='30s')
        for action in ('promote', 'demote', 'notify'):
            E.SubElement(ops, 'op', id=f'p-drbd-{resource}-{action}', name=action, interval='0', timeout='120s')
        E.SubElement(constraints, 'rsc_colocation', id='col-'+resource, rsc='g-nfs-ha',
                     **{'with-rsc': ident, 'with-rsc-role': 'Promoted', 'score': 'INFINITY'})
        E.SubElement(constraints, 'rsc_order', id='order-'+resource, first=ident,
                     **{'first-action': 'promote', 'then': 'g-nfs-ha', 'then-action': 'start',
                        'kind': 'Mandatory', 'symmetrical': 'true'})
    group = E.SubElement(resources, 'group', id='g-nfs-ha')
    attributes(group, 'meta_attributes', 'g-nfs-ha-meta', {'target-role': 'Stopped'})
    # Recovery state first; all four mounts precede NFS and every export.
    for resource, minor, mount in [LAYOUT[3], *LAYOUT[:3]]:
        primitive(group, 'p-fs-'+resource, 'heartbeat:Filesystem',
                  {'device': f'/dev/drbd{minor}', 'directory': mount, 'fstype': 'ext4',
                   'options': 'noatime', 'force_unmount': 'false'})
    primitive(group, 'p-nfs-server', 'heartbeat:nfsserver', {
        'nfs_shared_infodir': '/var/lib/nfs-ha/state', 'nfs_server_scope': scope,
        'nfs_ip': str(vip), 'nfs_init_script': '/usr/local/sbin/nfs-ha-nfsserver-control',
        'nfsv4_only': 'true'}, stop='120s')
    for (resource, _, mount), fsid in zip(LAYOUT[:3], fsids):
        options = 'rw,sync,wdelay,hide,no_subtree_check,sec=sys,secure,root_squash,no_all_squash'
        if resource in ('grafana', 'postgres'):
            uid = 472 if resource == 'grafana' else 999
            options += f',anonuid={uid},anongid={uid}'
        for i, client in enumerate(clients, 1):
            primitive(group, f'p-export-{resource}-{i}', 'heartbeat:exportfs', {
                'directory': mount, 'clientspec': client, 'options': options, 'fsid': fsid,
                # Two resources export the same filesystem. Do not unlock each other's locks.
                'unlock_on_stop': '0', 'wait_for_leasetime_on_stop': '1', 'rmtab_backup': 'none'},
                stop=f'{stop}s')
    primitive(group, 'p-nfs-vip', 'heartbeat:IPaddr2', {
        'ip': str(vip), 'cidr_netmask': env['NFS_HA_PREFIX'], 'nic': env['NFS_HA_INTERFACE']})
    for ident, attrs in restrictions().items():
        E.SubElement(constraints, 'rsc_location', id=ident, **attrs)
    return root


def write(root, path):
    E.indent(root)
    E.ElementTree(root).write(path, encoding='utf-8', xml_declaration=True)


def add_simulation_scores(root):
    # crm_simulate never executes the DRBD agent that normally publishes these.
    # Model healthy UpToDate disks ONLY in the simulation copy, never production.
    for i, node in enumerate(root.findall('./configuration/nodes/node')):
        attributes(node, 'instance_attributes', f'simulation-scores-{i}',
                   {'master-p-drbd-'+r: '10000' for r, _, _ in LAYOUT})


def main():
    out = Path(sys.argv[1]).resolve()
    if len(sys.argv) != 2:
        raise ValueError('Usage: nfs-ha-render.py NEW_OUTPUT_DIRECTORY')
    root = render(os.environ)
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    write(root, out/'cib-stopped.xml')
    simulation = copy.deepcopy(root)
    add_simulation_scores(simulation)
    for nv in simulation.findall('.//nvpair[@name="target-role"]'):
        nv.set('value', 'Started')
    write(simulation, out/'simulation-start.xml')
    (out/'corosync.conf').write_text('''# Candidate only: requires review, identical private authkey, and partition tests.
totem {
    version: 2
    cluster_name: nfs-ha
    transport: knet
    crypto_cipher: aes256
    crypto_hash: sha256
}
nodelist {
    node {
        ring0_addr: 192.168.1.194
        name: ubuntu-master2.koeppster.lan
        nodeid: 1
    }
    node {
        ring0_addr: 192.168.1.235
        name: ubuntu-slave1.koeppster.lan
        nodeid: 2
    }
}
quorum {
    provider: corosync_votequorum
    expected_votes: 2
    two_node: 0
    wait_for_all: 1
}
logging {
    to_syslog: yes
}
''')
    (out/'README.txt').write_text(
        'OFFLINE MASTER2-ONLY CANDIDATE. No reservation or live validation has occurred.\n'
        'No node fencing or automatic failover. Both votes are required; peer loss stops the service.\n'
        'Never submit simulation-start.xml. Follow pacemaker-cutover.md.\n')
    subprocess.run([str(Path(__file__).with_name('nfs-ha-validate-stage.sh')), str(out)], check=True)
    print(f'Private candidates: {out}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
