#!/usr/bin/env python3
"""Stage a stopped master2-only migration snapshot for a controlled restart."""
import argparse
import copy
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as E
from nfs_ha_phase import require_stopped


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restart', action='store_true', required=True,
                        help='Retain the master2-only restrictions for reactivation')
    parser.add_argument('snapshot', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    original = args.snapshot
    root = E.parse(original).getroot()
    load('cutover', 'nfs-ha-cutover.py').validate(root)
    require_stopped(root)
    candidate = copy.deepcopy(root)
    for status in candidate.findall('status'):
        candidate.remove(status)
    out = args.output
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    render = load('render', 'nfs-ha-render.py')
    render.write(candidate, out/'cib-stopped.xml')
    render.add_simulation_scores(candidate)
    for node in candidate.findall('.//nvpair[@name="target-role"]'):
        node.set('value', 'Started')
    render.write(candidate, out/'simulation-start.xml')
    # Membership/key remain unchanged: restart staging only validates the CIB.
    subprocess.run([str(Path(__file__).with_name('nfs-ha-validate-stage.sh')), str(out), '--cib-only'], check=True)
    print(f'Staged in {out}; use cutover activate. No live changes.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
