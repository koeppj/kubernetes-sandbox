# DRBD installation and one-time initialization

This procedure starts after all five backing LVs exist on both
`ubuntu-slave1` and `ubuntu-master2`. It installs software, installs the five
DRBD resource definitions, creates internal DRBD metadata on both peers, and
creates each ext4 filesystem once through its DRBD device.

It does not mount a filesystem, configure NFS exports, enable Corosync or
Pacemaker, assign a VIP, or submit a CIB. Those actions remain blocked until
the VIP, fencing, client networks, and legacy NFS service handoff are reviewed.

The one-time initialization source is `ubuntu-master2`. The source selection
does not copy any legacy data; all five new filesystems begin empty.

## 1. Install packages on both nodes

On each host, review the package simulation, then install:

```bash
cd /home/koeppj/projects/kubernetes-sandbox/nfs-ha
sudo ./scripts/nfs-ha-packages.sh
sudo ./scripts/nfs-ha-packages.sh --apply
```

The installer refuses simulations containing package upgrades, removals,
kernel packages, or DKMS. It suppresses package-triggered service starts. On
`ubuntu-slave1`, it does not stop or disable the existing NFS server.

After installation, compare the DRBD utility and kernel driver versions on the
two nodes. The planned baseline is the in-kernel DRBD 8.4.11 driver with Ubuntu's
`drbd-utils` package. Stop if the nodes report incompatible drivers or utility
behavior.

## 2. Review and install DRBD resource files

On each host:

```bash
sudo ./scripts/nfs-ha-drbd-config.sh
sudo ./scripts/nfs-ha-drbd-config.sh --apply
```

The preview checks the expected local IP, exact LV sizes, absence of mounted
filesystems/signatures, unused replication ports, and DRBD parser acceptance.
It prints the resource, DRBD device, backing LV, and destination file. Apply
installs only missing files in `/etc/drbd.d`; it refuses to overwrite a
different file.

Before continuing, compare the installed files on both hosts:

```bash
sudo sha256sum /etc/drbd.d/{nfs,kube,grafana,postgres,nfs-state}.res
sudo drbdadm dump all
```

The five hashes must match across the pair. Confirm that the DRBD node names
match `uname -n` (`ubuntu-slave1.koeppster.lan` and
`ubuntu-master2.koeppster.lan`), addresses
`192.168.1.235` and `192.168.1.194`, ports 7788–7792, devices `/dev/drbd0`
through `/dev/drbd4`, and every node-specific backing LV are correct.

## 3. Create metadata and connect the resources

Run the preview and apply on one node, then the other. The first node will wait
for its peer until the second node is ready.

```bash
sudo ./scripts/nfs-ha-drbd-metadata.sh
sudo ./scripts/nfs-ha-drbd-metadata.sh --apply
```

`create-md` writes internal metadata near the end of each new backing LV. This
is the first destructive DRBD step. The script stops if it detects existing
metadata, a filesystem signature, a mount, or an existing DRBD device. A
partially completed run is deliberately not repaired or skipped; inspect it
and run the remaining `drbdadm create-md` and `drbdadm up` commands manually.

After both nodes have completed, inspect both:

```bash
sudo drbdadm status
cat /proc/drbd
sudo drbdadm role all
sudo drbdadm cstate all
sudo drbdadm dstate all
```

All resources must be connected and Secondary on both nodes before source
initialization. Do not choose a synchronization source by guessing after any
unexpected state or partial initialization.

## 4. Initialize from `ubuntu-master2` and create ext4

Run only on `ubuntu-master2`:

```bash
sudo ./scripts/nfs-ha-drbd-init.sh --source ubuntu-master2
sudo ./scripts/nfs-ha-drbd-init.sh --source ubuntu-master2 --apply
```

The preview requires every resource to be `Connected`, `Secondary/Secondary`,
and `Inconsistent/Inconsistent`, with no signature or mount on its DRBD device.
Apply uses `drbdadm primary --force` once per resource to select the initial
source, then runs `mkfs.ext4` on the corresponding `/dev/drbdN` device. Never
run `mkfs` on a backing LV.

The script leaves all resources Primary on `ubuntu-master2`, unmounted, and
synchronizing or synchronized. Monitor both peers until every resource is
`UpToDate/UpToDate`:

```bash
watch -n 2 cat /proc/drbd
sudo drbdadm status
sudo blkid /dev/drbd0 /dev/drbd1 /dev/drbd2 /dev/drbd3 /dev/drbd4
```

Stop after synchronization. Filesystem mounting, NFS ownership, exports,
Pacemaker configuration, fencing, VIP activation, and legacy data copying are
later reviewed stages.
