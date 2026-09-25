resource kube {
    protocol C;

    net {
        allow-two-primaries no;
        after-sb-0pri disconnect;
        after-sb-1pri disconnect;
        after-sb-2pri disconnect;
        rr-conflict disconnect;
    }

    on ubuntu-slave1.koeppster.lan {
        device /dev/drbd1;
        disk /dev/kube-vg/drbd-kube;
        address 192.168.1.235:7789;
        meta-disk internal;
    }

    on ubuntu-master2.koeppster.lan {
        device /dev/drbd1;
        disk /dev/ubuntu-vg/drbd-kube;
        address 192.168.1.194:7789;
        meta-disk internal;
    }
}
