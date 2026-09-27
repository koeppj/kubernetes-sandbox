resource grafana {
    protocol C;

    disk {
        fencing resource-only;
    }

    handlers {
        fence-peer "/usr/lib/drbd/crm-fence-peer.sh";
        after-resync-target "/usr/lib/drbd/crm-unfence-peer.sh";
    }

    net {
        allow-two-primaries no;
        after-sb-0pri disconnect;
        after-sb-1pri disconnect;
        after-sb-2pri disconnect;
        rr-conflict disconnect;
    }

    on ubuntu-slave1.koeppster.lan {
        device /dev/drbd2;
        disk /dev/kube-vg/drbd-grafana;
        address 192.168.1.235:7790;
        meta-disk internal;
    }

    on ubuntu-master2.koeppster.lan {
        device /dev/drbd2;
        disk /dev/ubuntu-vg/drbd-grafana;
        address 192.168.1.194:7790;
        meta-disk internal;
    }
}
