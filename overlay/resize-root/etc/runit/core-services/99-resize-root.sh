# Resize rootfs to fill available partition space.
resize_root() {
	local root_mount="$(mount | grep ' / ' | grep -Ev 'loop|nbd')"
	if [ -z "$root_mount" ]; then
		msg "Resizing of loop/nbd based root not supported; ignoring..."
		return
	fi

	local root_par="$(echo "$root_mount" | cut -d' ' -f1)"
	local root_fs="$(echo "$root_mount" | cut -d' ' -f5)"
	local resize_cmd=""
	case "$root_fs" in
		ext*) resize_cmd="resize2fs" ;;
		f2fs) resize_cmd="resize.f2fs" ;;
		xfs) resize_cmd="xfs_growfs -d" ;;
		*) msg "Resizing of $root_fs formatted root not supported; ignoring..." ;;
	esac

	case "$root_par" in
		*.img) msg "Resizing of rootfs image files not supported; ignoring..." ;;
		*)
			if [ "$resize_cmd" ]; then
				msg "Resizing $root_fs root filesystem on $root_par..."
				$resize_cmd $root_par
			fi
		;;
	esac
}
resize_root; unset resize_root
rm /etc/runit/core-services/99-resize-root.sh
