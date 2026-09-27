#!/usr/bin/env python3
"""Read-only Kubernetes inventory and explicit per-claim rebind candidates."""
import argparse
import copy
import hashlib
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys

SHARES = {'kube-nfs': ('/srv/kube-lv', '/srv/ha/kube-lv'),
          'kube-grafana': ('/srv/kube-grafana', '/srv/ha/kube-grafana'),
          'kube-postgres': ('/srv/kube-postgres', '/srv/ha/kube-postgres')}


def rebind(pv, pvc, vip):
    spec = pv['spec']
    ns, claim = pvc['metadata']['namespace'], pvc['metadata']['name']
    if pvc.get('status', {}).get('phase') != 'Bound' or pv.get('status', {}).get('phase') != 'Bound':
        raise ValueError(f'{claim}: source must be Bound')
    if (spec['claimRef'].get('namespace'), spec['claimRef'].get('name'), spec['claimRef'].get('uid')) != (ns, claim, pvc['metadata']['uid']):
        raise ValueError('PV/PVC binding changed; recollect')
    if any(k in pvc['spec'] for k in ('dataSource', 'dataSourceRef')):
        raise ValueError('Data-source claims need a separately reviewed rebind')
    oldshare, newshare = SHARES[spec['storageClassName']]
    csi = spec.get('csi', {})
    attrs = csi.get('volumeAttributes', {})
    if csi.get('driver') != 'nfs.csi.k8s.io' or attrs.get('server') != '192.168.1.235' or attrs.get('share', '').rstrip('/') != oldshare:
        raise ValueError(f'{claim}: unexpected source driver/server/share; do not infer a copy path')
    if set(csi) - {'driver', 'volumeHandle', 'volumeAttributes', 'readOnly'}:
        raise ValueError('Unexpected CSI options; review manually')
    subdir = attrs.get('subdir', '')
    if not subdir or subdir.startswith('/') or any(p in ('', '.', '..') for p in subdir.split('/')) or '#' in subdir:
        raise ValueError('Require an explicit safe source subdir')
    target = str(PurePosixPath(newshare) / subdir)
    handle = f'{vip}#{newshare}#{subdir}'
    name = 'ha-' + hashlib.sha256(handle.encode()).hexdigest()[:32]
    newpv = {'apiVersion': 'v1', 'kind': 'PersistentVolume', 'metadata': {'name': name,
             'labels': copy.deepcopy(pv['metadata'].get('labels', {}))}, 'spec': copy.deepcopy(spec)}
    newpv['spec'].update({'claimRef': {'namespace': ns, 'name': claim},
                         'persistentVolumeReclaimPolicy': 'Retain',
                         'csi': {'driver': 'nfs.csi.k8s.io', 'volumeHandle': handle,
                                 'readOnly': csi.get('readOnly', False),
                                 'volumeAttributes': {'server': vip, 'share': target, 'mountPermissions': '0'}}})
    newpvc = {'apiVersion': 'v1', 'kind': 'PersistentVolumeClaim',
              'metadata': {'namespace': ns, 'name': claim,
                           'labels': copy.deepcopy(pvc['metadata'].get('labels', {}))},
              'spec': copy.deepcopy(pvc['spec'])}
    newpvc['spec']['volumeName'] = name
    mapping = {'namespace': ns, 'claim': claim, 'old_pv': pv['metadata']['name'],
               'old_pvc_uid': pvc['metadata']['uid'], 'new_pv': name,
               'source_host': 'ubuntu-slave1.koeppster.lan', 'source_path': oldshare+'/'+subdir,
               'target_host': 'ubuntu-master2.koeppster.lan', 'target_path': target,
               'vip': vip, 'validated': False, 'rollback_copy_authority': 'old until first new write'}
    return newpv, newpvc, mapping


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--namespace', required=True)
    p.add_argument('--claim', action='append', required=True, help='Repeat for every claim used by this stack')
    p.add_argument('--vip', required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    vip = ipaddress.IPv4Address(a.vip)
    if vip not in ipaddress.ip_network('192.168.1.0/24') or str(vip) in ('192.168.1.0', '192.168.1.255', '192.168.1.194', '192.168.1.235') or int(str(vip).split('.')[-1]) >= 243:
        p.error('Use the reviewed distinct VIP outside the observed MetalLB pool')
    if len(set(a.claim)) != len(a.claim):
        p.error('Duplicate claims')
    os.umask(0o077)
    a.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    def get(args):
        return json.loads(subprocess.check_output(['microk8s', 'kubectl', 'get', *args, '-o', 'json'], text=True))
    def save(name, data):
        (a.output/name).write_text(json.dumps(data, indent=2)+'\n')
    storage = get(['pv,sc'])
    workloads = get(['pvc,pods,deployments,statefulsets,jobs,cronjobs,hpa', '-n', a.namespace])
    save('storage-before.json', storage)
    save('workloads-before.json', workloads)
    pvs = {x['metadata']['name']: x for x in storage['items'] if x['kind'] == 'PersistentVolume'}
    claims = {x['metadata']['name']: x for x in workloads['items'] if x['kind'] == 'PersistentVolumeClaim'}
    planned_pvs, planned_pvcs, mappings = [], [], []
    for name in a.claim:
        pvc = claims[name]
        oldpv = pvs[pvc['spec']['volumeName']]
        pv, claim, mapping = rebind(oldpv, pvc, str(vip))
        if pv['metadata']['name'] in pvs or any(x['spec'].get('csi', {}).get('volumeHandle') == pv['spec']['csi']['volumeHandle'] for x in pvs.values()):
            raise ValueError('Destination PV/handle already exists; inspect prior migration')
        if any(x['metadata']['name'] == pv['metadata']['name'] for x in planned_pvs):
            raise ValueError('Multiple claims map to the same destination; review shared writers')
        planned_pvs.append(pv)
        planned_pvcs.append(claim)
        mappings.append(mapping)
        save('retain-'+oldpv['metadata']['name']+'.json', {'spec': {'persistentVolumeReclaimPolicy': 'Retain'}})
    save('new-pvs.json', {'apiVersion': 'v1', 'kind': 'List', 'items': planned_pvs})
    save('new-pvcs.json', {'apiVersion': 'v1', 'kind': 'List', 'items': planned_pvcs})
    save('migration-map.json', mappings)
    print(f'Private stack plan: {a.output}. No writes to Kubernetes or NFS. Follow gradual-migration.md.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
