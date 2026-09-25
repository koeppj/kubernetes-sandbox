resource nfs {
    protocol C;

    net {
        allow-two-primaries no;
        after-sb-0pri disconnect;
        after-sb-1pri disconnect;
        after-sb-2pri disconnect;
        rr-conflict disconnect;
    }

    on ubuntu-slave1.koeppster.lan {
        device /dev/drbd0;
        disk /dev/nfs-vg/drbd-nfs;
        address 192.168.1.235:7788;
        meta-disk internal;
    }

    on ubuntu-master2.koeppster.lan {
        device /dev/drbd0;
        disk /dev/ubuntu-vg/drbd-nfs;
        address 192.168.1.194:7788;
        meta-disk internal;
    }
}
