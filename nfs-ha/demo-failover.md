# Optional one-host operation for the demo cluster

The September 27 CIB is master2-only and stops NFS when either Corosync vote
is lost. This optional mode changes **only Pacemaker configuration**: it sets
`no-quorum-policy=ignore`, removes the five permanent slave1 bans, and adds a
strong preference for the current NFS owner. The existing four DRBD
promotion/order/colocation rules and NFS group remain intact. This permits
Pacemaker to keep NFS on the surviving primary or try to promote the survivor
if the primary disappears. It also means an isolated peer cannot be fenced.

Run from an account with passwordless `sudo` and SSH to both hosts. Both hosts
must be online, the current NFS group healthy, and all four DRBD resources
Connected and UpToDate/UpToDate. Preview before changing the live CIB:

```bash
./bin/configure-nfs-demo-failover.py enable
./bin/configure-nfs-demo-failover.py enable --execute
```

The preview checks both one-host scheduling cases with `crm_simulate`. It
does not prove live DRBD promotion, NFS recovery or client behavior. Test one
**controlled host shutdown at a time** before relying on unexpected-failure
takeover. Confirm the survivor has all four DRBD resources Primary, four HA
mounts, six exports and VIP `192.168.1.240`; test PVC I/O and application
startup. On peer return, wait for all replicas to become Connected and
UpToDate/UpToDate before another maintenance action. The owner preference
can move the service back when the preferred host rejoins, causing a second
NFS interruption; check `pcs status --full` before resuming heavy workloads.

Planned handoffs can still use [the switch helper](maintenance-handoff.md)
while both hosts are healthy. In demo mode, it changes the preferred owner,
and the other host remains eligible for takeover. The handoff still requires
writers to be stopped so NFS clients reconnect cleanly.

To restore the original two-vote master2-only policy, first switch NFS back
to master2 while both hosts are online, then run:

```bash
./bin/configure-nfs-demo-failover.py disable
./bin/configure-nfs-demo-failover.py disable --execute
```

This is a deliberate demo tradeoff. A link, NIC or switch fault can isolate
two still-running hosts even on one LAN. Without node fencing or a tie-breaker,
both partitions may believe they can own the service and VIP; DRBD can end up
with divergent data. A missing host alone does not prove it is powered off.
Do not use this mode for data that cannot be discarded or rebuilt.
