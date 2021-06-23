#!/bin/bash -e

# Runtime vars
###############
IMG=""
resize_gb="8"
target="/data/void-rootfs.img"
nbd_target=false
force_kill_nbd=false
overwrite=false
reboot=true

# Functions
############
log() { echo ">> $1"; }
die() { echo -e "$1" 1>&2; exit 1; }
err() { die "ERROR: $1"; }
usage() { die "usage: $0 [-i rootfs.img] [-s rootfs_resize_gb] [-t target_location] [-f] [-k] [-R]"; }
parse_args() {
	while getopts ":i:s:t:fkR" OPT; do
		case "$OPT" in
			i) IMG="$OPTARG" ;;
			s) resize_gb=$OPTARG ;;
			t) target="$OPTARG" ;;
			f) overwrite=true ;;
			k) force_kill_nbd=true ;;
			R) reboot=false ;;
			*) usage ;;
		esac
	done
	[ "$target" = "nbd" ] && nbd_target=true || :
}
print_config() {
	echo "Deployment configuration:

  rootfs: $IMG
  target: $target
  size:   ${resize_gb}G"
	if $nbd_target; then
		echo "  kill:   $force_kill_nbd"
	else
		echo "  reboot: $reboot"
	fi
	echo
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
		echo "  $i. $r (${SIZES[(($i-1))]})"
	done
	echo
	[ $OPTS_NUM -eq 1 ] && \
		read -p "Choice (1) >> " i ||
		read -p "Choice (1-$i) >> " i
	IMG="${OPTS[(($i-1))]}"
}
unpack_img() {
	rm -f rootfs.img # cleanup
	if [[ "$IMG" = *".img" ]]; then # not compressed
		ln -s "$IMG" rootfs.img
		return
	fi

	log "Unpacking '$IMG'..."
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
get_mode() {
	[ "$(fastboot devices)" ] && echo "fastboot" && return
	[[ "$(adb devices)" = *"recovery"* ]] && echo "recovery" && return
	echo "unknown"
}
droid_wait_device() {
	log "Waiting for a device in recovery or fastboot mode..."
	mode="$(get_mode)"
	while [ "$mode" = "unknown" ]; do
		sleep 2
		mode="$(get_mode)"
	done
	[ "$mode" = "recovery" ] && device="$(adb shell getprop ro.product.device)" || :
}
droid_deploy_recovery() {
	local par_target=false
	if adb shell test -e /dev/block/bootdevice/by-name/$target; then
		par_target=true
		local par_name="$target"
		local blk_target="/dev/block/bootdevice/by-name/$target"
	fi

	if ! $overwrite && adb shell test -e $target; then
		read -erp ">> Overwrite existing $target (y/N)? " ans
		[[ "${ans^^}" != "Y"* ]] && exit 0
	fi

	$par_target && target="/tmp/$target.img" || :

	log "Transferring as $(basename $target)..."
	adb push rootfs.img $target

	if $par_target; then
		log "Writing rootfs image using dd..."
		adb shell "dd if=$target of=$blk_target bs=4m && rm $target"

		target="$blk_target"
		log "Resizing rootfs to fit device's $par_name partition..."
		adb shell "resize2fs $target"
	else
		log "Resizing rootfs on device to $resize_gb GiB..."
		adb shell "resize2fs $target ${resize_gb}G"
	fi
}
fastboot_get_pars() {
	fastboot getvar all 2>&1 | grep -Po 'partition-type:\K.*(?=:)'
}
droid_deploy_fastboot() {
	fastboot_get_pars | grep -q "$target" \
		|| err "A partition named '$target' doesn't exist on device;
       please change it via e.g. '-t system'!"

	log "Flashing rootfs to device partition $target via fastboot..."
	fastboot flash $target rootfs.img
}
droid_deploy_img() {
	log "Detected your ${device:-device} in $mode mode!"
	if [ "$mode" = "recovery" ]; then
		droid_deploy_recovery
	elif [ "$mode" = "fastboot" ]; then
		droid_deploy_fastboot
	fi
	rm rootfs.img
}
mount_rootfs() {
	adb shell << EOF
mkdir /a
mount $target /a
EOF
}
umount_rootfs() {
	adb shell << EOF
umount /a
rmdir /a
sync
EOF
}
droid_flash_kernel() {
	mount_rootfs
	if ! adb shell test -e /a/boot/boot.img; then
		umount_rootfs
		return
	fi

	log "Flashing /boot/boot.img from rootfs..."
	adb shell "dd bs=4m if=/a/boot/boot.img of=/dev/block/bootdevice/by-name/boot"
	umount_rootfs
}
droid_reboot() {
	log "Rebooting device..."
	if [ "$mode" = "recovery" ]; then
		adb shell "reboot"
	elif [ "$mode" = "fastboot" ]; then
		fastboot reboot
	fi
}
droid_flash() {
	droid_wait_device
	droid_deploy_img
	[ "$mode" = "recovery" ] && droid_flash_kernel
	$reboot && droid_reboot || :
}
nbd_prepare() {
	local pid="$(pgrep -f "nbd-server -C $PWD/nbd/config" | head -1)"
	if [ "$pid" ]; then
		if ! $force_kill_nbd; then
			read -erp ">> Stop the still-running nbd-server (pid $pid) (Y/n)? " ans
			[[ -z "${ans}" || "${ans}" = "Y"* ]] || exit 0
		fi
		log "Stopping existing nbd-server process (pid $pid)..."
		kill $pid
	fi
}
nbd_setup() {
	local rootfs="$(readlink -f "$PWD/rootfs.img")"
	sed -e "s/@NPROC@/$(nproc)/" -e "s|@ROOTFS@|$rootfs|" \
		nbd/config.in > nbd/config
	if [ -e nbd/allowed_clients ]; then
		sed -e "s/@AUTHFILE@/authfile = allowed_clients/" -i nbd/config
	else
		sed -e "/@AUTHFILE@/d" -i nbd/config
	fi

	# TODO: e2fsck?
	log "Resizing $(basename "$rootfs") to $resize_gb GiB..."
	resize2fs "$rootfs" ${resize_gb}G
	log "Starting nbd-server..."
	nbd-server -C $PWD/nbd/config
	log "Available NBD shares on this PC:"
	nbd-client -l 127.0.0.1 | tail +2
}

# Script
#########
cd "$(readlink -f "$(dirname "$0")")"
parse_args $@
prepare
choose_img
print_config
nbd_prepare
if ! $nbd_target; then
	unpack_img
	droid_flash
else
	if [ -e rootfs.img ]; then
		if ! $overwrite; then
			read -erp ">> Previous rootfs.img found; replace it with a fresh copy of $(basename "$IMG") (y/N)? " ans
			[[ "${ans^^}" = "Y"* ]] && overwrite=true
		fi
		$overwrite && unpack_img || :
	else
		unpack_img
	fi
	nbd_setup
fi
log "Done!"
