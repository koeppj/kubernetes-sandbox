#!/usr/bin/env python3
"""Check migrated PVC bindings before a component deploy changes anything.

Print `CLAIM EXISTING` for a verified migrated claim. Print `CLAIM NEW` only
when no migrated PV from this cluster exists, which is a fresh installation.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAPPING = ROOT / "storage-class-mapping.json"


def kubectl(*args):
    return subprocess.check_output(
        ["microk8s", "kubectl", *args], text=True, stderr=subprocess.PIPE
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("namespace")
    parser.add_argument("claims", nargs="+")
    args = parser.parse_args()

    mapping = json.loads(MAPPING.read_text())
    known = {(x["namespace"], x["claim"]): x for x in mapping["migrated_claims"]}
    requested = []
    for claim in args.claims:
        key = (args.namespace, claim)
        if key not in known:
            raise ValueError(f"No reviewed migrated-claim mapping for {key}")
        requested.append(known[key])

    namespace = kubectl("get", "namespace", args.namespace, "--ignore-not-found", "-o", "json")
    pvcs = (
        {
            x["metadata"]["name"]: x
            for x in json.loads(kubectl("get", "pvc", "-n", args.namespace, "-o", "json"))["items"]
        }
        if namespace.strip()
        else {}
    )
    pvs = {
        x["metadata"]["name"]: x
        for x in json.loads(kubectl("get", "pv", "-o", "json"))["items"]
    }
    classes = {
        x["metadata"]["name"]: x
        for x in json.loads(kubectl("get", "storageclass", "-o", "json"))["items"]
    }
    migrated_pvs_present = any(x["pv"] in pvs for x in mapping["migrated_claims"])
    results = []
    for expected in requested:
        claim = expected["claim"]
        storage_class = classes.get(expected["storage_class"])
        target = next(x["target_endpoint"] for x in mapping["classes"] if x["name"] == expected["storage_class"])
        if storage_class is not None and any(storage_class["parameters"].get(k) != target[k] for k in ("server", "share")):
            raise ValueError(f"StorageClass {expected['storage_class']} has the wrong endpoint")
        if storage_class is None and migrated_pvs_present:
            raise ValueError(f"StorageClass {expected['storage_class']} is missing in a migrated cluster")
        pvc = pvcs.get(claim)
        if pvc is None:
            if migrated_pvs_present:
                raise ValueError(f"{args.namespace}/{claim} is missing in a migrated cluster; recover its original binding")
            results.append((claim, "NEW"))
            continue

        pv = pvs.get(expected["pv"])
        if pv is None:
            raise ValueError(f"Expected PV {expected['pv']} is missing for {args.namespace}/{claim}")
        actual = {
            "pvc_uid": pvc["metadata"]["uid"],
            "pvc_phase": pvc["status"]["phase"],
            "pvc_pv": pvc["spec"].get("volumeName"),
            "pvc_class": pvc["spec"].get("storageClassName"),
            "pv_uid": pv["metadata"]["uid"],
            "pv_phase": pv["status"]["phase"],
            "pv_claim_uid": pv["spec"].get("claimRef", {}).get("uid"),
            "pv_class": pv["spec"].get("storageClassName"),
            "pv_reclaim": pv["spec"].get("persistentVolumeReclaimPolicy"),
            "pv_driver": pv["spec"].get("csi", {}).get("driver"),
            "server": pv["spec"].get("csi", {}).get("volumeAttributes", {}).get("server"),
            "share": pv["spec"].get("csi", {}).get("volumeAttributes", {}).get("share"),
        }
        required = {
            "pvc_uid": expected["pvc_uid"],
            "pvc_phase": "Bound",
            "pvc_pv": expected["pv"],
            "pvc_class": expected["storage_class"],
            "pv_uid": expected["pv_uid"],
            "pv_phase": "Bound",
            "pv_claim_uid": expected["pvc_uid"],
            "pv_class": expected["storage_class"],
            "pv_reclaim": "Retain",
            "pv_driver": "nfs.csi.k8s.io",
            "server": expected["server"],
            "share": expected["share"],
        }
        mismatches = [key for key, value in required.items() if actual[key] != value]
        if mismatches:
            raise ValueError(f"{args.namespace}/{claim} binding differs in: {', '.join(mismatches)}")
        results.append((claim, "EXISTING"))

    for claim, state in results:
        print(claim, state)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(f"Migrated PVC preflight failed: {exc}")
