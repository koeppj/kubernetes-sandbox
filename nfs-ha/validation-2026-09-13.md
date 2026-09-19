# Local preparation validation — 2026-09-13

Host: `ubuntu-master2.koeppster.lan`.

## Completed

- Implemented four shell entrypoints with shared Python validation and mocked safety tests.
- Reconfirmed approved VG/PV UUIDs, Linux parent serial, stable PV alias, root LV UUID and 100 GiB size, and single-PV VG membership.
- Refreshed configured Ubuntu package indexes. The immediately following simulation reported 81 new packages, zero upgrades, and zero removals.
- Installed the complete step 2 package set, including `pacemaker-cli-utils`, with no general upgrade, autoremove, kernel installation, or reboot.
- Suppressed package starts using a temporary `policy-rc.d`, and suppressed `needrestart`. The original absent policy was restored after installation.
- Confirmed NFS server, DRBD startup/helper services, Corosync, Pacemaker, pcsd (including Ruby service), and SMART services are masked and inactive. NFS client services were not masked.
- Verified no active NFS exports and no DRBD block devices.
- Confirmed existing NFS mount inventory is identical before/after. Listening endpoints are unchanged; raw `ss` text differs only in systemd file descriptor numbers for existing SSH listeners, with unchanged SSH PID.
- All four Kubernetes nodes remain Ready. Existing `boxmcp/boxmcp-demo-55f69cbffb-4662h` CrashLoopBackOff was recorded before installation; no new unhealthy pods were found afterward.
- `dpkg --audit` is clean. Repeated package simulation reports zero new packages, upgrades, or removals.
- Twelve mocked tests, Bash syntax checks on each entrypoint, and ShellCheck pass.
- Staged and validated the local layout at `/var/lib/nfs-ha-preparation/staging-steps-1-2/preparation.json`.

## Not completed / gates

**No new LVs were created.** The original root LV is still the sole LV in `ubuntu-vg`, which retains approximately 2692.52 GiB free. No formatting, partition changes, Windows disk operations, DRBD initialization, HA activation, or Kubernetes manifest changes were performed.

At the time of the installation run, LV creation was blocked on off-host backup and disposable-VM evidence. This requirement was subsequently superseded by the operator's request for direct LVM commands and manual QA. The current creation script has no backup/evidence gates. LV creation is now pending the operator's manual review and execution.

The configuration command currently stages the preparation layout only. Step 3 DRBD/NFS/Pacemaker templates, peer validation, and CRM validation are outside this implementation and remain pending, along with all production activation gates.

## Evidence

Private timestamped command logs, before/after package and health inventories, and the preparation staging output are under `/var/lib/nfs-ha-preparation/` (root-only). No metadata backup or off-host backup was made during the installation run. The revised LVM script does not create backups; these are optional operator precautions.


## Follow-up: simplified LV creation

- Replaced the Python-backed LVM entrypoint with five direct `lvcreate` commands against the approved Linux PV, followed by an `lvs` report.
- Removed the automated backup/VM-evidence gates, UUID ledger, and plan/create/grow modes. No-argument execution creates LVs immediately; arguments are rejected.
- Preflight and staging accept the manually created layout without a private UUID ledger. Existing host/storage checks remain in those tools.
- Updated the implementation plan, README, and mocked checks for the revised manual workflow.
- The creation script was not executed during this change. Storage creation remains for the operator after manual QA.
- Follow-up validation: all nine remaining mocked checks, per-file Bash syntax checks, and ShellCheck pass. These checks did not execute LV creation.
