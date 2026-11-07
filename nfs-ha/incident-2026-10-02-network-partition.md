# October 2 NFS HA network partition: incident and recovery plan

Status checked October 3, 2026 at 12:41 UTC. The October 2 event was **unplanned**. This document records the observed behavior, a proposed recovery assuming `ubuntu-slave1` is authoritative, and ways to retain one-host NFS service without repeating the unsafe takeover. No DRBD recovery or cluster redesign described below has been executed.

## What happened

The two storage hosts shared one LAN for Corosync and DRBD. The demo configuration had `no-quorum-policy=ignore`, `stonith-enabled=false`, and `startup-fencing=false`. DRBD used `fencing resource-only` with Pacemaker CIB constraints, but neither node had an independent power-fencing device. A missing Corosync peer therefore did not prove it was powered off.

| October 2, UTC | Evidence and effect |
| --- | --- |
| 08:28:02–11 | `ubuntu-master2` lost carrier on `enp2s0`; its link flapped repeatedly. Both hosts logged DRBD ping timeouts and all four connections became `StandAlone`. DRBD could not bind its configured LAN address during the flap. The precise cable, NIC, or switch cause has not been established. |
| 08:28:10–16 | Pacemaker on `ubuntu-slave1` promoted `kube`, `grafana`, `postgres`, and `nfs-state`. The DRBD peer-fencing handlers reported the other node unreachable. `ubuntu-master2` was still Primary. |
| 08:28:17–33 | Slave1 mounted the four HA filesystems, started NFS and the six exports, and added VIP `192.168.1.240` at 08:28:33. Master2 had not stopped its NFS group. This was overlapping ownership, not an orderly handoff. |
| 08:29:18 | Pacemaker stopped the VIP on both nodes and began stopping exports. A VIP-backed Kubernetes client could potentially have reached slave1 during the brief 08:28:33–08:29:18 window, but the available logs do not prove a successful application write then. Slave1's first NFS start also logged client-tracking errors. |
| 08:29–08:46 | The six `exportfs` stops ran in group order. Each had `wait_for_leasetime_on_stop=1` and took about 92 seconds for the NFSv4 lease; changing cluster membership also interrupted transitions. Master2's NFS server and DRBD filesystems remained active during much of this period. |
| 08:46:20–33 | Master2 finally stopped NFS, unmounted the four filesystems, and demoted all four DRBD resources. The demotion actions succeeded; they had been held behind the ordered NFS shutdown. |
| 08:46:32–46 | Slave1 rebuilt the NFS group, restored the VIP at 08:46:44, and ended its NFSv4 grace period at 08:46:46. Master2's NFS client logs reported the VIP responding again at 08:46:45. VIP-backed workloads that remained running could resume writes to slave1 around this point. The logs do not identify the first successful application write. |

Both hosts were Primary for roughly 18 minutes without replication. Master2 had local DRBD writes while disconnected; slave1 became the serving NFS owner. Treat their data generations as potentially divergent. Pacemaker's `promoted-max=1` and the existing promotion/colocation/order constraints applied only within each communicating partition; they could not establish that the peer had stopped. The six lease waits explain the slow demotion, but shortening them would not prove exclusive ownership.

## State at the October 3 checkpoint

- Both Pacemaker nodes were online with two votes, and the NFS group, six exports, and VIP were running on slave1. Master2 was Secondary.
- On both hosts, all four DRBD resources were `StandAlone` with `UpToDate/Outdated` disk status. They were **not replicating**.
- Four `drbd-fence-by-handler-*` location constraints barred promotion on master2. These were created by DRBD's resource-fencing integration and currently prevent takeover onto master2. The demo owner preference still points to master2; it may cause a move after the fencing constraints are removed.
- Pacemaker still recorded failed `p-nfs-vip` and `p-export-postgres-2` monitor actions. PCSD authentication warnings were separate from the storage failure.
- On October 3, `./bin/shutdown-nfs-workloads.sh` scaled the eight active NFS-backed Deployments and StatefulSets to zero. The older `n8n/postgres-n8n` StatefulSet was already at zero. The helper saved counts in `../bin/.nfs-workload-replicas.tsv`; do not discard that file before restore. No running Kubernetes Pod had an NFS PVC or direct NFS volume at the check. Ubuntu-mini retained a legacy NFS mount, but `fuser` found no process using it. Check other direct or external clients again before recovery.

## Recovery Steps

This choice discards master2's divergent modifications. The October 2 overlap means the discarded copy might contain writes that never reached slave1. Preserve evidence and any data that might need later comparison before resynchronizing. [LINBIT's DRBD 8.4 manual recovery procedure](https://linbit.com/drbd-user-guide/users-guide-drbd-8-4/) describes the victim/survivor sequence used here; the installed kernel module reports DRBD 8.4.11.

1. Keep the Kubernetes and other NFS writers stopped. Confirm both hosts' LAN addresses and links are stable and investigate the October 2 carrier flap. Confirm slave1 still owns all four DRBD Primaries and the NFS group; master2 must remain Secondary with no HA mounts or VIP.
2. Make a recoverable backup of slave1's authoritative data. If any master2-only writes might matter, preserve master2's four backing volumes separately **before** using `--discard-my-data`. Arrange a consistent backup point for the filesystems and databases rather than assuming a live file copy is consistent.
3. Recover one DRBD resource at a time. For `kube`, run on **master2** (the copy to discard):

   ```bash
   sudo drbdadm disconnect kube
   sudo drbdadm secondary kube
   sudo drbdadm connect --discard-my-data kube
   ```

   Then run on **slave1** (the authoritative copy):

   ```bash
   sudo drbdadm disconnect kube
   sudo drbdadm connect kube
   ```

   Check that master2 becomes the resynchronization target and slave1 the source, then wait for `Connected` and `UpToDate/UpToDate` on **both** hosts. Repeat separately for `grafana`, `postgres`, and `nfs-state`. Stop if roles, direction, or disk states differ from the expected result. Do not force promotion or mount master2's DRBD filesystems.
4. Check `pcs status --full`, both DRBD states, the four mounts, six exports, and VIP. The configured `after-resync-target` handler should remove each DRBD promotion restriction after synchronization. Do not remove those constraints manually before verifying full replication. The existing preference for master2 can cause a failback and another NFS interruption when it becomes eligible; keep writers stopped until placement is stable and reviewed.
5. When NFS placement and replication are stable, run `./bin/restore-nfs-workloads.sh` from the same MicroK8s control-plane checkout that holds the saved replica file. Verify PostgreSQL readiness, application endpoints, and PVC reads and writes. Review the recorded monitor failures before clearing them; do not treat a clean display as proof of data consistency.

The [maintenance handoff](maintenance-handoff.md) and [demo failover](demo-failover.md) procedures apply only after both DRBD copies are synchronized. Do not run a live failover test in the current disconnected state.

## Configuration choices that retain one-host operation

**Recommended: third vote plus tested node fencing.** Keep DRBD and NFS on the two storage hosts. Add a Corosync QDevice on an independent host/path, or add a third voting Pacemaker member that cannot run any DRBD clone or the NFS group. Configure and test independent power fencing for **both** storage hosts; enable Pacemaker fencing and startup fencing, and use a quorum policy that stops an inquorate partition. The side holding quorum must confirm the old owner is fenced before promoting DRBD and starting NFS. If the current owner fails, the surviving storage host plus the third vote can remain quorate, fence the old owner, and run alone. If the third vote or fence path is unavailable, the cluster should withhold takeover rather than guess. A third vote by itself is insufficient: on October 2, stopping the old owner took about 18 minutes.

**Two storage hosts with independent power fencing, without a third vote.** This can retain one-host service with a carefully designed two-node quorum policy, but a network partition can make both sides race to fence each other. Configure and test an asymmetric fencing delay or priority and an independent fence path, accepting that a bad partition may stop both hosts. This is less deterministic than a third vote plus fencing. Do not enable STONITH without working, tested fence devices.

**Interim containment while no fencing exists.** Restore the original `no-quorum-policy=stop` two-vote behavior after recovery. That prevents the isolated side from automatically starting a replacement NFS service, but it also sacrifices unattended one-host availability. It does not resolve the present divergence. The current `no-quorum-policy=ignore` and `stonith-enabled=false` combination should remain a disposable-data demo setting only.

For both one-host designs, add a redundant cluster/DRBD communication path and repair the physical link. Redundancy reduces partitions but cannot replace fencing. Do not rely on a longer promotion delay, `promoted-max=1`, or the DRBD `resource-only` CIB handler as proof that a disconnected Primary is off. [Pacemaker's fencing overview](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/assembly_overview-of-high-availability-configuring-and-managing-high-availability-clusters), [Ubuntu's QDevice documentation](https://manpages.ubuntu.com/manpages/noble/man8/corosync-qdevice.8.html), and [LINBIT's DRBD/Pacemaker guidance](https://linbit.com/drbd-user-guide/users-guide-drbd-8-4/) describe these mechanisms.

Adding a third **Pacemaker** node also requires updating this repository's two-host assumptions before deployment. `../bin/switch-nfs-primary.py` and `../bin/configure-nfs-demo-failover.py` validate exactly two CIB nodes and two votes; `scripts/nfs-ha-render.py` renders only two members, and the historical cutover checks assume the original layout. QDevice avoids adding a third Pacemaker resource node but still requires a reviewed Corosync configuration, runbooks, and partition/fencing tests.
