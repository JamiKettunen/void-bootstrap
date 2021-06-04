#!/bin/bash -e

# Runtime vars
###############
IMG=""
resize_gb="8"
# TODO: allow flashing to partition or even directory!
target_file="/data/void-rootfs.img"
reboot=true

# Functions
############
die() { echo -e "$1" 1>&2; exit 1; }
err() { die "ERROR: $1"; }
usage() { die "usage: $0 [-i rootfs.img] [-s rootfs_resize_gb] [-t target_location] [-R]"; }
parse_args() {
	while getopts ":i:s:t:R" OPT; do
		case "$OPT" in
			i) IMG="$OPTARG" ;;
			s) resize_gb=$OPTARG ;;
			t) target_file="$OPTARG" ;;
			R) reboot=false ;;
			*) usage ;;
		esac
	done
}
print_config() {
	echo "Deployment configuration:

  rootfs: $IMG
  target: $target_file
  size:   ${resize_gb}G
  reboot: $reboot
"
}
prepare() {
	OPTS=($(ls images/*rootfs*.img* 2>/dev/null || :))
	OPTS_NUM=${#OPTS[@]}
	[ $OPTS_NUM -eq 0 ] && err "No rootfs to deploy; please run ./mkrootfs.sh first!"
	SIZES=($(du -sh images/*rootfs*.img* | awk '{print $1}'))
}
choose_img() {
	[ "$IMG" ] && return # configured via cmdline
	echo "Choose rootfs to deploy:"
	echo
	i=0
	for r in ${OPTS[@]}; do
		((i++)) || :
		r="${r##*/}" # strip "images/" prefix
		#r="${r%.*}" # drop ".img*" extension
		echo "  $i. $r (${SIZES[(($i-1))]})"
	done
	echo
	[ $OPTS_NUM -eq 1 ] && \
		read -p "Choice (1) >> " i ||
		read -p "Choice (1-$i) >> " i
	IMG="${OPTS[(($i-1))]}"
	# IMG=images/aarch64-musl-rootfs-op5-2021-06-03.img
}
unpack_img() {
	rm -f rootfs.img # cleanup

	if [[ "$IMG" = *".img" ]]; then # not compressed
		ln -s "$IMG" rootfs.img
		#cp "$IMG" rootfs.img
		return
	fi

	echo ">> Unpacking '$IMG'..."
	if [[ "$IMG" = *".xz" ]]; then
		hash pixz &>/dev/null \
			&& pixz -kd "$IMG" rootfs.img \
			|| unxz --keep "$IMG" rootfs.img
	elif [[ "$IMG" = *".gz" ]]; then
		hash pigz &>/dev/null \
			&& pigz -dc "$IMG" > rootfs.img \
			|| gzip -dc "$IMG" > rootfs.img
	else
		err "No decompression handler to unpack '$IMG'!"
	fi
}
# TODO: Allow flashing to partition from fastboot mode!
wait_recovery() {
	device=""
	echo ">> Waiting for a device in recovery mode..."
	while true; do
		if adb devices | grep -q recovery; then
			device="$(adb shell getprop ro.product.device)"
			break
		fi
		sleep 1
	done
}
deploy_img() {
	echo ">> Detected your '$device' in recovery mode!"
	if adb shell test -e $target_file; then
		read -erp ">> Overwrite existing $target_file (y/N)? " ans
		[[ "${ans^^}" != "Y"* ]] && exit 0
	fi
	echo ">> transferring as $(basename $target_file)..."
	adb push rootfs.img $target_file
	rm rootfs.img
	echo ">> Resizing rootfs on device to $resize_gb GiB..."
	adb shell "resize2fs $target_file ${resize_gb}G"
}
mount_rootfs() {
	adb shell << EOF
mkdir /a
mount $target_file /a
EOF
}
umount_rootfs() {
	adb shell << EOF
umount /a
rmdir /a
sync
EOF
}
flash_kernel() {
	mount_rootfs
	if ! adb shell test -e /a/boot/boot.img; then
		umount_rootfs
		return
	fi

	echo ">> Flashing /boot/boot.img from rootfs..."
	adb shell "dd bs=4m if=/a/boot/boot.img of=/dev/block/bootdevice/by-name/boot"
	#umount_rootfs
}

# Script
#########
parse_args $@
prepare
choose_img
print_config
wait_recovery
unpack_img
deploy_img
flash_kernel
$reboot && adb shell "reboot"
echo ">> Done!"
