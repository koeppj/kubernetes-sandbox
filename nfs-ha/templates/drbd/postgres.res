resource postgres {
    protocol C;

    net {
        allow-two-primaries no;
        after-sb-0pri disconnect;
        after-sb-1pri disconnect;
        after-sb-2pri disconnect;
        rr-conflict disconnect;
    }

    on ubuntu-slave1.koeppster.lan {
        device /dev/drbd3;
        disk /dev/kube-vg/drbd-postgres;
        address 192.168.1.235:7791;
        meta-disk internal;
    }

    on ubuntu-master2.koeppster.lan {
        device /dev/drbd3;
        disk /dev/ubuntu-vg/drbd-postgres;
        address 192.168.1.194:7791;
        meta-disk internal;
    }
}
