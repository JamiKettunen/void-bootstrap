#!/bin/bash
# Make rootfs timezone match the host.
host_timezone() {
	if [ ! -e /etc/localtime ]; then
		warn "/etc/localtime doesn't exist on host"
		return
	fi
	$sudo ln -sf "$(readlink -f /etc/localtime)" "$rootfs_dir"/etc/localtime
}
host_timezone
