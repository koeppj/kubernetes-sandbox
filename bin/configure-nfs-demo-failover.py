#!/usr/bin/env python3
"""Preview or configure unfenced, one-host NFS operation for this demo cluster."""

import argparse
import copy
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


def load_handoff():
    sys.dont_write_bytecode = True
    path = Path(__file__).with_name('switch-nfs-primary.py')
    spec = importlib.util.spec_from_file_location('nfs_handoff', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def change(root, handoff, action, current):
    result = copy.deepcopy(root)
    props = result.find('./configuration/crm_config/cluster_property_set[@id="nfs-ha-properties"]')
    quorum = props.find('./nvpair[@name="no-quorum-policy"]') if props is not None else None
    if quorum is None:
        raise ValueError('Expected no-quorum-policy property is missing')
    constraints = result.find('./configuration/constraints')
    if action == 'enable':
        quorum.set('value', 'ignore')
        for item in list(constraints):
            if item.get('id', '').startswith('migration-'):
                constraints.remove(item)
        ET.SubElement(constraints, 'rsc_location', id=handoff.DEMO_PREFERENCE,
                      rsc='g-nfs-ha', node=current, score='100000')
    else:
        if current != handoff.HOSTS[0]:
            raise ValueError('Switch NFS back to master2 before restoring the original restrictions')
        quorum.set('value', 'stop')
        preference = constraints.find(f'./rsc_location[@id="{handoff.DEMO_PREFERENCE}"]')
        constraints.remove(preference)
        ET.SubElement(constraints, 'rsc_location', id='migration-service-ban',
                      rsc='g-nfs-ha', node=handoff.HOSTS[1], score='-INFINITY',
                      **{'resource-discovery': 'never'})
        for resource in handoff.RESOURCES:
            ET.SubElement(constraints, 'rsc_location', id='migration-promote-ban-' + resource,
                          rsc='cl-drbd-' + resource, node=handoff.HOSTS[1],
                          score='-INFINITY', role='Promoted')
    handoff.validate_configuration(result)
    return result


def simulate(handoff, path, action, current):
    for lost in handoff.HOSTS:
        survivor = next(h for h in handoff.HOSTS if h != lost)
        output = handoff.command(['crm_simulate', '-S', '-x', str(path),
                                  '--node-down=' + lost, '--quorum=false'], privileged=True)
        if action == 'enable':
            if lost == current:
                expected = r'^\s*\* Resource action:\s+p-nfs-vip\s+start on ' + re.escape(survivor) + r'\s*$'
            else:
                expected = r'^\s*\* p-nfs-vip\s+.*Started ' + re.escape(survivor) + r'\s*$'
            if not re.search(expected, output, re.MULTILINE):
                raise ValueError('One-host simulation failed with ' + lost + ' offline')
        elif re.search(r'^\s*\* Resource action:\s+p-nfs-vip\s+start on ', output, re.MULTILINE):
            raise ValueError('Restored two-vote mode unexpectedly starts a VIP without quorum')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('enable', 'disable'))
    parser.add_argument('--execute', action='store_true', help='Apply the reviewed CIB change')
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error('Run as a regular user with passwordless sudo')
    handoff = load_handoff()
    root = handoff.xml_command(['cibadmin', '--query'], privileged=True)
    preferred = handoff.validate_configuration(root)
    demo = root.find(f'./configuration/constraints/rsc_location[@id="{handoff.DEMO_PREFERENCE}"]') is not None
    if demo == (args.action == 'enable'):
        raise ValueError('Requested demo mode is already configured')
    status = handoff.xml_command(['crm_mon', '--one-shot', '--output-as=xml'], privileged=True)
    handoff.validate_runtime(status, preferred)
    quorum = handoff.command(['corosync-quorumtool', '-s'], privileged=True)
    if not all(re.search(r'^' + re.escape(field) + r':\s+2\s*$', quorum, re.MULTILINE)
               for field in ('Nodes', 'Expected votes', 'Total votes', 'Quorum')):
        raise ValueError('Both hosts and two-vote quorum are required for this configuration change')
    for host in handoff.HOSTS:
        handoff.require_replication(host, 'Primary/Secondary' if host == preferred else 'Secondary/Primary',
                                    remote=host != handoff.command(['hostname', '-f']).strip())
    handoff.check_target(next(host for host in handoff.HOSTS if host != preferred))
    candidate = change(root, handoff, args.action, preferred)
    with tempfile.TemporaryDirectory(prefix='nfs-demo-failover-') as directory:
        path = Path(directory)
        path.chmod(0o700)
        cib = path / 'candidate.xml'
        config = path / 'configuration.xml'
        ET.ElementTree(candidate).write(cib, encoding='unicode', xml_declaration=True)
        ET.ElementTree(candidate.find('configuration')).write(config, encoding='unicode', xml_declaration=True)
        handoff.command(['crm_verify', '-x', str(cib), '-V'], privileged=True)
        simulate(handoff, cib, args.action, preferred)
        print(f'Validated {args.action} preview with both one-host Pacemaker simulations.')
        if args.action == 'enable':
            print('Demo mode ignores quorum loss and allows takeover on either host without node fencing.')
        else:
            print('Original master2-only, two-vote policy will be restored.')
        if not args.execute:
            print('Preview only; rerun with --execute to apply.')
            return
        latest = handoff.xml_command(['cibadmin', '--query'], privileged=True)
        if ET.tostring(latest.find('configuration')) != ET.tostring(root.find('configuration')):
            raise ValueError('Cluster configuration changed during preflight; rerun preview')
        handoff.command(['cibadmin', '--replace', '--scope', 'configuration',
                         '--xml-file', str(config)], privileged=True)
        applied = handoff.xml_command(['cibadmin', '--query'], privileged=True)
        if handoff.validate_configuration(applied) != preferred:
            raise ValueError('CIB update returned, but preferred owner differs; inspect pcs status')
        print('Applied. Validate a controlled single-host outage before relying on failover.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError) as exc:
        print(f'Demo failover configuration stopped: {exc}', file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            print(exc.stderr.strip(), file=sys.stderr)
        sys.exit(1)
