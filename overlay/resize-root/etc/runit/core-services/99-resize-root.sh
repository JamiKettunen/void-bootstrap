#!/bin/sh
# Resize rootfs to fill available partition space.
resize_root() {
	local root_mount="$(grep ' / ' /proc/mounts | grep -Ev 'loop|nbd')"
	if [ "$root_mount" ]; then
		local root_par="$(echo "$root_mount" | cut -d' ' -f1)"
		local root_fs="$(echo "$root_mount" | cut -d' ' -f3)"
		if [ "$root_fs" = "ext4" ]; then
			msg "Resizing $root_fs root filesystem on $root_par..."
			resize2fs $root_par
		else
			msg "Resizing of $root_fs formatted root not supported; ignoring..."
		fi
	else
		msg "Resizing of loop/nbd based root not supported; ignoring..."
	fi
}
resize_root; unset resize_root
rm /etc/runit/core-services/99-resize-root.sh
