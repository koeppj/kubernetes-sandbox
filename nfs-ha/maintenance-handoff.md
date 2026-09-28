# Planned NFS primary handoff

`bin/switch-nfs-primary.py` moves all four DRBD primaries, the NFS group, and
VIP `192.168.1.240` together. In the original two-vote mode, it moves the
five placement bans so the old owner is banned. In the optional
[demo failover mode](demo-failover.md), it changes the preferred owner while
both hosts remain eligible. Pacemaker's
existing ordering and colocation rules stop NFS and its mounts before DRBD
demotion, then start them only after promotion on the new host. There is no
automatic failover or direct `drbdadm primary` operation.

The command previews by default. Run it **on the current NFS owner** as a
normal user with passwordless `sudo` and SSH access to the other host. The
same user needs passwordless remote `sudo` for read-only DRBD checks. Install
the current repository version on both hosts before a maintenance window.
This command does not run Kubernetes maintenance helpers for you.

## Master2 to slave1

1. On a MicroK8s control-plane host, review both maintenance dry runs:
   `./bin/shutdown-nfs-workloads.sh --dry-run` and
   `./bin/restore-nfs-workloads.sh --dry-run`. Inventory Jobs,
   DaemonSets, unmanaged Pods, direct NFS mounts, and other writers, since the
   helper does not cover those. Record their stop and restart actions.
2. On `ubuntu-master2`, preview the handoff:

   ```bash
   ./bin/switch-nfs-primary.py --to ubuntu-slave1.koeppster.lan
   ```

3. Stop NFS-backed workloads using `./bin/shutdown-nfs-workloads.sh` from the
   control-plane host. Stop any other writers identified in step 1 and confirm
   their NFS I/O has ended. Keep the helper's replica state file for restore.
4. On `ubuntu-master2`, perform the handoff:

   ```bash
   ./bin/switch-nfs-primary.py --to ubuntu-slave1.koeppster.lan \
     --execute --writers-stopped
   ```

5. Check `pcs status --full` on both hosts, `drbdadm status` on each, the four
   HA mounts, all six exports, and the VIP on slave1. Check that master2 is
   Secondary and has no HA mount or VIP. Restore workloads with
   `./bin/restore-nfs-workloads.sh` on the same control-plane host, then test
   PVC reads and writes, PostgreSQL readiness, and application endpoints.

## Slave1 back to master2

Run the same discovery and writer-stop steps. The preview and execution
commands now run **on `ubuntu-slave1`**:

```bash
./bin/switch-nfs-primary.py --to ubuntu-master2.koeppster.lan
./bin/switch-nfs-primary.py --to ubuntu-master2.koeppster.lan \
  --execute --writers-stopped
```

Check all four DRBD resources, mounts, exports and VIP on master2, and no
HA mount or VIP on slave1. Restore the saved replica counts and validate
application I/O as above. Do not delete or clear the five placement bans;
the script moves them to the node that should remain ineligible.

The script requires both hosts online, two-vote quorum, connected and
UpToDate DRBD replicas, an inactive NFS service and no HA mounts on the
target, the expected Pacemaker resource layout, and a healthy current
owner. It runs `crm_verify` and `crm_simulate` against the proposed CIB before
changing only the constraints section. An execution failure leaves the last
cluster state in place for diagnosis; inspect `pcs status --full`, both DRBD
states, mounts, and the VIP before retrying. Never force DRBD promotion or
mount either ext4 filesystem directly.

## Host shutdown and quorum

In the original mode, this handoff changes primary placement but does not
allow one-host service. The current cluster requires two votes and has
`no-quorum-policy=stop`. Once
either host leaves Corosync, Pacemaker stops NFS on the remaining host if it
can complete stop actions. Plan an NFS outage before taking a host offline,
even after moving primary. Restore both hosts, check DRBD is fully
synchronized and quorum is two, then resume clients. Keeping NFS available
with one host offline requires a separately designed and tested quorum and
isolation mechanism. The [optional demo mode](demo-failover.md) deliberately
accepts this risk and enables one-host operation after offline simulation and
live validation.

The historical `nfs-ha` cutover and restart scripts still validate the
master2-only migration layout. Do not run their activate/stop actions while
the five bans point at master2 or while demo mode is enabled; this handoff
script is the supported path for switching between the two current hosts.
