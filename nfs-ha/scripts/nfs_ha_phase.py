"""Offline invariants for the master2-only migration service."""
import copy
import xml.etree.ElementTree as E

PEER = 'ubuntu-slave1.koeppster.lan'
RESOURCES = ('kube', 'grafana', 'postgres', 'nfs-state')


def restrictions():
    result = {'migration-service-ban': {'rsc': 'g-nfs-ha', 'node': PEER,
              'score': '-INFINITY', 'resource-discovery': 'never'}}
    for resource in RESOURCES:
        result['migration-promote-ban-'+resource] = {
            'rsc': 'cl-drbd-'+resource, 'node': PEER, 'score': '-INFINITY', 'role': 'Promoted'}
    return result


def phase(root):
    constraints = root.find('./configuration/constraints')
    if constraints is None:
        raise ValueError('Missing constraints')
    found = {x.get('id'): x for x in constraints if x.get('id', '').startswith('migration-')}
    if not found:
        raise ValueError('Master2-only migration restrictions are required')
    expected = restrictions()
    if set(found) != set(expected):
        raise ValueError('Incomplete migration restrictions')
    for ident, attrs in expected.items():
        if found[ident].tag != 'rsc_location' or dict(found[ident].attrib) != {'id': ident, **attrs} or len(found[ident]):
            raise ValueError('Altered migration restriction: '+ident)
    return 'migration'


def require_stopped(root):
    for ident in ['g-nfs-ha', *['cl-drbd-'+r for r in RESOURCES]]:
        resource = root.find(f'./configuration/resources/*[@id="{ident}"]')
        if resource is None or resource.find('./meta_attributes/nvpair[@name="target-role"][@value="Stopped"]') is None:
            raise ValueError('Stop the migration group and all clones before staging a restart')


def normalized(root):
    cfg = copy.deepcopy(root.find('configuration'))
    for node in cfg.iter():
        node.text = None
        node.tail = None
        values = sorted(node.attrib.items())
        node.attrib.clear()
        node.attrib.update(values)
    return E.tostring(cfg)

