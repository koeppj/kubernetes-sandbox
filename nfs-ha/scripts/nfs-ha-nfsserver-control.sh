#!/bin/sh
# Resource-agent adapter: Debian's legacy init script reports a stopped nfsd
# as running and skips startup when /etc/exports is empty. Exports are managed
# by Pacemaker here, so control the systemd unit directly and verify its state.
set -eu

unit=nfs-server.service
threads_file=/proc/fs/nfsd/threads

case "${1-}" in
    start)
        systemctl start "$unit"
        ;;
    stop)
        systemctl stop "$unit"
        for dependency in nfs-mountd.service nfs-idmapd.service nfsdcld.service rpc-statd.service proc-fs-nfsd.mount; do
            systemctl stop "$dependency"
        done
        ;;
    status|monitor)
        systemctl is-active --quiet "$unit" || exit 3
        systemctl is-active --quiet proc-fs-nfsd.mount || exit 3
        systemctl is-active --quiet nfs-mountd.service || exit 3
        systemctl is-active --quiet nfsdcld.service || exit 3
        [ -r "$threads_file" ] || exit 3
        threads=$(cat "$threads_file") || exit 3
        [ "$threads" -gt 0 ] || exit 3
        ;;
    *)
        echo "Usage: $0 {start|stop|status}" >&2
        exit 2
        ;;
esac
