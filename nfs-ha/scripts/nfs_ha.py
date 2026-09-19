#!/usr/bin/env python3
"""Local preparation only. Never initialize DRBD, format, export, or activate HA."""
import argparse
import contextlib
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

HOST = 'ubuntu-master2.koeppster.lan'
VG = 'ubuntu-vg'
VG_UUID = '7tSlFd-Td5w-6UIS-8Q9H-QsyJ-wAjy-AggOQz'
PV_UUID = 'hCi2Mc-JjMO-q15R-Jtb6-lR4z-lzi4-R8394T'
PV = '/dev/disk/by-id/ata-WDC_WD30EZRX-00D8PB0_WD-WMC4N0H7PM9A-part3'
SERIAL = 'WD-WMC4N0H7PM9A'
ROOT_UUID = '2fQkbV-VOcG-xatJ-qTUs-EYsY-BszZ-HCuXz9'
GIB = 1024 ** 3
LAYOUT = {'nfs': 100, 'kube': 200, 'grafana': 5, 'postgres': 50, 'nfs-state': 1}
MOUNTS = dict(zip(LAYOUT, ['/srv/nfs-lv', '/srv/kube-lv', '/srv/kube-grafana', '/srv/kube-postgres', '/var/lib/nfs-ha']))
STATE = Path('/var/lib/nfs-ha-preparation')
PACKAGES = 'lvm2 drbd-utils pacemaker pacemaker-cli-utils corosync pcs resource-agents-base resource-agents-extra nfs-kernel-server nfs-common rsync acl attr smartmontools shellcheck'.split()
# Do not mask rpcbind, statd, idmapd, or nfs-client.target: this node is an NFS client.
UNITS = 'nfs-server.service nfs-kernel-server.service nfs-mountd.service proc-fs-nfsd.mount drbd.service drbd@.service corosync.service pacemaker.service pcsd.service pcsd-ruby.service pcsd.socket fsidd.service nfsdcld.service drbd-promote@.service drbd-lvchange@.service drbd-demote-or-escalate@.service drbd-reconfigure-suspend-or-error@.service drbd-wait-promotable@.service smartd.service smartmontools.service'.split()
GATES = ['tested independent fencing', 'quorum and DRBD fencing design', 'verified peer storage and DRBD versions', 'reserved VIP and network design', 'authoritative exports and client inventory', 'backup and isolated recovery test']
LOG = None


def emit(message):
    line = f'{datetime.datetime.now(datetime.timezone.utc).isoformat()} {message}'
    print(line, flush=True)
    if LOG:
        LOG.write(line + '\n')
        LOG.flush()


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(args, check=True, env=None):
    result = subprocess.run([str(a) for a in args], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr.strip()}')
    return result


def rows(command, fields, key):
    result = run([command, '--reportformat', 'json', '--units', 'b', '--nosuffix', '-o', fields])
    return json.loads(result.stdout)['report'][0][key]


def inventory():
    return {
        'host': run(['hostname', '-f']).stdout.strip(),
        'pv_path': os.path.realpath(PV),
        'parent': run(['lsblk', '-ndo', 'PKNAME', PV]).stdout.strip(),
        'pvs': rows('pvs', 'pv_name,pv_uuid,vg_name,pv_free', 'pv'),
        'vgs': rows('vgs', 'vg_name,vg_uuid,vg_free', 'vg'),
        'lvs': rows('lvs', 'lv_name,lv_uuid,vg_name,lv_size,segtype,devices,lv_attr', 'lv'),
    }


def validate(data, serial, root_source):
    require(data['host'] == HOST, 'Wrong host')
    require(serial == SERIAL, 'Wrong parent disk serial (Windows disk is excluded)')
    pvs = [p for p in data['pvs'] if p['vg_name'] == VG]
    require(len(pvs) == 1, 'Unexpected VG PV membership')
    require(pvs[0]['pv_uuid'] == PV_UUID and os.path.realpath(pvs[0]['pv_name']) == data['pv_path'], 'PV identity mismatch')
    vgs = [v for v in data['vgs'] if v['vg_name'] == VG]
    require(len(vgs) == 1 and vgs[0]['vg_uuid'] == VG_UUID, 'VG identity mismatch')
    roots = [v for v in data['lvs'] if v['vg_name'] == VG and v['lv_name'] == 'ubuntu-lv']
    require(len(roots) == 1 and roots[0]['lv_uuid'] == ROOT_UUID and int(float(roots[0]['lv_size'])) == 100 * GIB, 'Root LV identity/size changed')
    require(os.path.realpath(root_source) == os.path.realpath(f'/dev/{VG}/ubuntu-lv'), 'Unexpected root filesystem backing device')
    require(data['pv_path'] != os.path.realpath(root_source), 'PV resolves to root LV')
    for lv in [v for v in data['lvs'] if v['vg_name'] == VG]:
        require(lv['lv_name'] in ['ubuntu-lv'] + ['drbd-' + r for r in LAYOUT], 'Unexpected existing LV')
        require(lv['segtype'] == 'linear' and lv['lv_attr'].startswith('-'), 'LV is not ordinary linear storage')
        devices = lv['devices'].split(',')
        require(all(os.path.realpath(d.strip().split('(')[0]) == data['pv_path'] for d in devices), 'Unexpected LV backing device')
    require(min(float(vgs[0]['vg_free']), float(pvs[0]['pv_free'])) >= 512 * GIB, 'VG reserve below 512 GiB')
    return int(min(float(vgs[0]['vg_free']), float(pvs[0]['pv_free'])))


def checked():
    data = inventory()
    require(re.fullmatch(r'[a-zA-Z0-9_-]+', data['parent']) is not None, 'Ambiguous PV parent')
    serial = run(['lsblk', '-ndo', 'SERIAL', '/dev/' + data['parent']]).stdout.strip()
    root_source = run(['findmnt', '-n', '-o', 'SOURCE', '/']).stdout.strip()
    free = validate(data, serial, root_source)
    return data, free


def save_json(path, value):
    tmp = path.with_suffix(path.suffix + '.tmp')
    with tmp.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)
    fd = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def allocation(data):
    # Creation is manual; validate the resulting layout without a private UUID ledger.
    existing = {v['lv_name'][5:]: v for v in data['lvs'] if v['vg_name'] == VG and v['lv_name'].startswith('drbd-')}
    for name, lv in existing.items():
        require(name in LAYOUT, f'Unknown resource: {name}')
        require(int(float(lv['lv_size'])) == LAYOUT[name] * GIB,
                f'LV size differs from preparation layout: {name}')
    return existing


def capacity(free, delta):
    require(delta >= 0 and free - delta * GIB >= 512 * GIB, 'Allocation would violate 512 GiB reserve')


def health():
    commands = [
        ['dpkg-query', '-W', '-f=${binary:Package}\t${Version}\t${db:Status-Status}\n', *PACKAGES],
        ['systemctl', 'list-units', '--all', '--no-pager'],
        ['findmnt', '-rn', '-t', 'nfs,nfs4', '-o', 'TARGET,SOURCE,FSTYPE,OPTIONS'],
        ['microk8s', 'kubectl', 'get', 'nodes', '-o', 'json'],
        ['microk8s', 'kubectl', 'get', 'pods', '-A', '-o', 'json'],
        ['ss', '-lntup'], ['modinfo', 'drbd'],
    ]
    result = {}
    for command in commands:
        output = run(command, check=False)
        result[' '.join(command)] = {'status': output.returncode, 'stdout': output.stdout, 'stderr': output.stderr}
    return result


def check_health(snapshot, before=None):
    for kind in ('nodes', 'pods'):
        key = next(k for k in snapshot if f'get {kind}' in k)
        require(snapshot[key]['status'] == 0, f'Cannot inspect Kubernetes {kind}')
        items = json.loads(snapshot[key]['stdout'])['items']
        if kind == 'nodes':
            require(items and all(any(c['type'] == 'Ready' and c['status'] == 'True'
                                     for c in n['status']['conditions']) for n in items), 'Kubernetes node not Ready')
        else:
            def unhealthy(pods):
                return {p['metadata']['namespace'] + '/' + p['metadata']['name'] for p in pods
                        if p['status']['phase'] not in ('Running', 'Succeeded') or
                        (p['status']['phase'] == 'Running' and
                         any(not c.get('ready') for c in p['status'].get('containerStatuses', [])))}
            bad = unhealthy(items)
            if before:
                old = unhealthy(json.loads(before[key]['stdout'])['items'])
                require(bad <= old, f'New unhealthy pods: {bad - old}')
            elif bad:
                emit(f'Existing unhealthy pods recorded as baseline: {sorted(bad)}')
    if before:
        key = next(k for k in snapshot if k.startswith('findmnt '))
        require(set(before[key]['stdout'].splitlines()) <= set(snapshot[key]['stdout'].splitlines()), 'An existing NFS mount disappeared or changed')


def inactive():
    for unit in UNITS:
        if '@.' in unit:
            instances = json.loads(run(['systemctl', 'list-units', '--all', '--output=json', unit.replace('@.', '@*.')]).stdout)
            require(all(u['active'] in ('inactive', 'failed') for u in instances), f'Active instance of {unit}')
            continue
        status = run(['systemctl', 'show', unit, '-p', 'ActiveState', '--value']).stdout.strip()
        require(status in ('inactive', 'failed', ''), f'{unit} is {status}; refusing to interrupt it')


def preflight():
    data, free = checked()
    existing = allocation(data)
    delta = sum(size for name, size in LAYOUT.items() if name not in existing)
    capacity(free, delta)
    emit(json.dumps(data, indent=2))
    emit(f'Free: {free / GIB:.2f} GiB; missing allocation: {delta} GiB; remaining: {free / GIB - delta:.2f} GiB')
    emit(json.dumps(health(), indent=2))
    emit('Activation BLOCKED: ' + '; '.join(GATES))


def check_simulation(text):
    require(re.search(r'^0 upgraded, \d+ newly installed, 0 to remove', text, re.M), 'Simulation contains upgrades/removals or unrecognized summary')
    require(not re.search(r'^(Remv |Inst \S+ \[)', text, re.M), 'Simulation changes existing packages')
    require(not re.search(r'^Inst (linux-(image|headers|modules)|.*dkms)', text, re.M), 'Unexpected kernel/DKMS installation')


@contextlib.contextmanager
def suppress_starts(policy=Path('/usr/sbin/policy-rc.d')):
    backup = policy.with_name('policy-rc.d.nfs-ha-original')
    require(not backup.exists() and not backup.is_symlink(), f'Stale installation policy backup: {backup}')
    existed = policy.exists() or policy.is_symlink()
    moved = False
    installed = False
    try:
        if existed:
            policy.rename(backup)
            moved = True
        with policy.open('x') as stream:
            installed = True
            stream.write('#!/bin/sh\n# Temporary NFS HA preparation boundary\nexit 101\n')
        policy.chmod(0o755)
        yield
    finally:
        if installed:
            policy.unlink()
        if moved:
            backup.rename(policy)


def packages(apply):
    checked()
    inactive()
    if not apply:
        simulation = run(['apt-get', '-s', 'install', '--no-install-recommends', *PACKAGES]).stdout
        emit(simulation)
        check_simulation(simulation)
        return
    before = health()
    check_health(before)
    save_json(STATE / f'packages-before-{stamp()}.json', before)
    require(not run(['dpkg', '--audit']).stdout.strip(), 'dpkg has unfinished work')
    checked()
    emit(run(['apt-get', 'update', '-o', 'APT::Update::Error-Mode=any']).stdout)
    simulation = run(['apt-get', '-s', 'install', '--no-install-recommends', *PACKAGES]).stdout
    emit(simulation)
    check_simulation(simulation)
    # Persistent masks intentionally survive success/failure and reboot.
    checked()
    inactive()
    run(['systemctl', 'mask', *UNITS])
    try:
        with suppress_starts():
            checked()
            env = dict(os.environ, DEBIAN_FRONTEND='noninteractive', NEEDRESTART_MODE='l', NEEDRESTART_SUSPEND='1')
            emit(run(['apt-get', '--assume-yes', '--no-remove', '--no-upgrade',
                      '-o', 'Dpkg::Options::=--force-confold', 'install', '--no-install-recommends', *PACKAGES], env=env).stdout)
    finally:
        save_json(STATE / f'packages-after-{stamp()}.json', health())
    checked()
    inactive()
    check_health(health(), before)
    for unit in UNITS:
        require(run(['systemctl', 'is-enabled', unit], check=False).stdout.strip() == 'masked', f'{unit} not masked')
    emit('Packages installed; HA/server/SMART startup remains masked. Review before/after health snapshots.')


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')


def config(args):
    data, _ = checked()
    allocation(data)
    # Steps 1–2 provide the staging interface. Live DRBD/NFS/CIB templates are step 3.
    folder = Path(args.output).resolve()
    require(not folder.exists(), 'Staging destination must not exist')
    require(not str(folder).startswith(('/etc/', '/dev/', '/proc/', '/sys/')), 'Unsafe staging destination')
    folder.mkdir(mode=0o700, parents=True)
    manifest = {'stage': 'local-preparation-only', 'activation_allowed': False,
                'kernel_baseline': '8.4.11', 'unresolved': GATES,
                'resources': [{'name': n, 'backing_lv': f'/dev/{VG}/drbd-{n}', 'size_gib': s,
                               'future_mount': MOUNTS[n], 'exported': n != 'nfs-state'} for n, s in LAYOUT.items()]}
    save_json(folder / 'preparation.json', manifest)
    require(json.loads((folder / 'preparation.json').read_text()) == manifest, 'Staging validation failed')
    emit(f'Validated preparation layout in {folder}; step 3 configuration and crm validation are deferred')


def main():
    global LOG
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('preflight')
    pkg = sub.add_parser('packages')
    pkg.add_argument('--apply', action='store_true')
    cfg = sub.add_parser('config')
    cfg.add_argument('--output', required=True)
    args = parser.parse_args()
    require(os.geteuid() == 0, 'Run with sudo')
    # Logging/lock files are the only writes in preflight and dry-run modes.
    STATE.mkdir(mode=0o700, exist_ok=True)
    with (STATE / 'preparation.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with (STATE / f'{args.command}-{stamp()}.log').open('x') as log:
            LOG = log
            signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
            signal.signal(signal.SIGHUP, lambda *_: sys.exit(129))
            try:
                if args.command == 'preflight':
                    preflight()
                elif args.command == 'packages':
                    packages(args.apply)
                else:
                    config(args)
            except BaseException as exc:
                emit(f'FAILED: {exc}. Partial changes are preserved; inspect logs before retrying.')
                raise
            finally:
                LOG = None


if __name__ == '__main__':
    main()
