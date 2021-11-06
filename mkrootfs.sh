#!/usr/bin/env bash
set -e
#set -x # Debug

# Constants
############
SUPPORTED_ARCHES=(aarch64 armv6l armv7l x86_64 i686)
SPECIAL_MOUNTS=(sys dev proc)
DEF_MIRROR="https://alpha.de.repo.voidlinux.org"
COLOR_GREEN="\e[32m"
COLOR_BLUE="\e[36m"
COLOR_RED="\e[91m"
COLOR_YELLOW="\e[33m"
COLOR_RESET="\e[0m"

# Runtime vars
###############
config="config.custom.sh"
config_overrides=()
base_dir="$(readlink -f "$(dirname "$0")")"
host_arch="$(uname -m)" # e.g. "x86_64"
qemu_arch="" # e.g. "aarch64" / "arm"
musl_suffix="" # e.g. "-musl"
rootfs_match="" # e.g. "aarch64-musl-ROOTFS"
rootfs_dir="" # e.g. "/tmp/void-bootstrap/rootfs"
rootfs_tarball="" # e.g. "void-aarch64-musl-ROOTFS-20210218.tar.xz"
tarball_dir="$base_dir/tarballs"
chroot="" # e.g. "chroot" or "systemd-nspawn -q -D"
build_extra_pkgs=true
extra_pkg_steps_only=()
missing_deps=()
user_count=0
sudo="sudo" # prefix for commands requiring root user privileges; unset if running as root
usernames=()

# Functions
############
die() { echo -e "$1" 1>&2; exit 1; }
usage() { die "usage: $0 [-a alternate_arch] [-B] [-b] [-c alternate_config.sh] [-f] [-m musl_enable] [-N] [-u]"; }
error() { die "${COLOR_RED}ERROR: $1${COLOR_RESET}"; }
log() { echo -e "${COLOR_BLUE}>>${COLOR_RESET} $1"; }
warn() { echo -e "${COLOR_YELLOW}WARN: $1${COLOR_RESET}" 1>&2; }
cmd_path() { command -v $1; }
cmd_exists() { cmd_path $1 >/dev/null; }
escape_color() { local c="COLOR_$1"; printf '%q' "${!c}" | sed "s/^''$//"; }
rootfs_echo() { echo -e "$1" | $sudo tee "$rootfs_dir/$2" >/dev/null; }
get_rootfs_mounts() { grep "$rootfs_dir" /proc/mounts | awk '{print $2}' || :; }
run_script() { [ -e "$base_dir/mkrootfs.$1.sh" ] && . "$base_dir/mkrootfs.$1.sh" || :; }
copy_script() { [ -e "$base_dir/mkrootfs.$1.sh" ] && $sudo cp "$base_dir/mkrootfs.$1.sh" "$rootfs_dir"/ || :; }
parse_args() {
	while [ $# -gt 0 ]; do
		case $1 in
			-a|--arch) config_overrides+=("arch=$2"); shift ;;
			-B|--no-build-pkgs) build_extra_pkgs=false ;;
			-b|--build-pkgs-only) unset extra_install_pkgs; build_extra_pkgs=true; extra_pkg_steps_only+=(build) ;;
			-c|--config) config="$2"; shift ;;
			-f|--force-rebuild) config_overrides+=("unset XBPS_PRESERVE_PKGS") ;;
			-m|--musl) config_overrides+=("musl=$2"); shift ;;
			-N|--no-color) unset COLOR_GREEN COLOR_BLUE COLOR_RED COLOR_RESET ;;
			-u|--check-updates-only) extra_pkg_steps_only+=(check) ;;
			*) usage ;;
		esac
		shift
	done
}
config_prep() {
	[ $EUID -eq 0 ] && unset sudo
	cd "$base_dir"
	. config.sh
	[ -r "$config" ] && . "$config" || config="config.sh"
	for override in "${config_overrides[@]}"; do
		eval "$override" # e.g. "arch=armv7l"
	done
	echo " ${SUPPORTED_ARCHES[@]} " | grep -q " $arch " || error "Target architecture '$arch' is invalid!"
	if [ "$arch" = "i686" ]; then
		$musl && error "$arch doesn't have a musl rootfs variant available!"
	fi
	if [ "$host_arch" != "$arch" ]; then
		case "$arch" in
			"armv"*) qemu_arch="arm" ;;
			"i686") qemu_arch="i386" ;;
			*) qemu_arch="$arch" ;;
		esac
	fi
	$musl && musl_suffix="-musl"
	rootfs_match="$arch$musl_suffix-ROOTFS" # musl/glibc
	if [ -z "$backend" ]; then
		cmd_exists systemd-nspawn && backend="systemd-nspawn" || backend="chroot"
	fi
	[ "$work_dir" ] || work_dir="."
	work_dir="$(readlink -f "$work_dir")"
	rootfs_dir="$work_dir/rootfs"
	[ -d "$rootfs_dir" ] || mkdir -p "$rootfs_dir"
	[ "$mirror" ] || mirror="$DEF_MIRROR"
	[ "$img_compress" ] || img_compress="none"
	user_count=$(printf '%s\n' "${users[@]}" | grep -v ^root | wc -l)
	printf '%s\n' "${users[@]}" | grep -q ^root || users+=(root)
	[[ $((${#extra_build_pkgs[@]}+${#extra_install_pkgs[@]})) -gt 0 ]] || build_extra_pkgs=false
	. xbps-env.sh
}
check_deps() {
	runtime_deps=($backend wget xz mkfs.ext4 $sudo)
	[ "$img_compress" = "gz" ] && runtime_deps+=(gzip)
	if [ "$qemu_arch" ]; then
		runtime_deps+=(qemu-$qemu_arch-static)
		[ "$backend" != "systemd-nspawn" ] && runtime_deps+=(update-binfmts)
	fi
	[ ${#extra_build_pkgs[@]} -gt 0 ] && runtime_deps+=(git)

	for dep in ${runtime_deps[@]}; do
		cmd_exists $dep || missing_deps+=($dep)
	done
	local error_count=${#missing_deps[@]}
	[ $error_count -eq 0 ] && return

	missing_deps="${missing_deps[@]}"
	error "$error_count missing runtime dependencies found:

   $missing_deps
"
}
# Fold while offsetting ouput lines after the first one by $1 spaces.
fold_offset() {
	local fold_at=80
	local offset=$1; shift
	local spaces="" i=1
	for i in $(seq 1 $offset); do spaces+=" "; done
	i=1
	echo "$@" | fold -w $fold_at -s | while read -r line; do
		[ $i -eq 1 ] && echo "$line" || echo "$spaces$line"
		i=$((i+1))
	done
}
print_config() {
	echo "General configuration:

  host:     $host_arch
  arch:     $arch
  release:  $release
  backend:  $backend
  musl:     $musl
  mirror:   $mirror
  users:    $user_count
  hostname: $hostname"
if [ "$pkgcache_dir" ]; then
	echo "  pkgcache: $pkgcache_dir"
else
	echo "  pkgcache: none"
fi
if [ ${#overlays[@]} -gt 0 ]; then
	echo "  overlays: $(fold_offset 12 "${overlays[@]}")"
else
	echo "  overlays: none"
fi
echo "  work:     $work_dir
  config:   $config

Extra packages:
"
if [ ${#extra_install_pkgs[@]} -gt 0 ]; then
	echo "  build:    $build_extra_pkgs
  install:  $(fold_offset 12 "${extra_install_pkgs[@]}")"
else
	echo "  build: $build_extra_pkgs"
fi
echo

	echo "Image details:

  name extra: ${img_name_extra:-none}
  size max:   $img_size
  compress:   $img_compress
"
}
fetch_rootfs() {
	rootfs_tarball="$(wget "$mirror/live/$release/" -t 3 -qO - | grep $rootfs_match | cut -d'"' -f2)"
	log "Latest tarball: $rootfs_tarball"
	[ "$rootfs_tarball" ] || error "Please check your arch ($arch) and mirror ($mirror)!"
	local tarball_url="$mirror/live/$release/$rootfs_tarball"
	[ -e "$tarball_dir/$rootfs_tarball" ] && return

	log "Downloading rootfs tarball..."
	mkdir -p "$tarball_dir"
	wget "$tarball_url" -t 3 --show-progress -qO "$tarball_dir/$rootfs_tarball"

	log "Verifying tarball SHA256 checksum..."
	local filenames=() checksums=""
	for file in sha256sums sha256sum sha256; do
		checksums="$(wget "$mirror/live/$release/$file.txt" -t 3 -qO - || :)"
		[ "$checksums" ] && break
	done
	local checksum="$(sha256sum "$tarball_dir/$rootfs_tarball" | awk '{print $1}')"
	echo "$checksums" | grep -qe "$rootfs_tarball" -e "$checksum" && return

	rm "$tarball_dir/$rootfs_tarball"
	error "Rootfs tarball checksum verification failed; please try again!"
}
umount_rootfs_special() {
	local rootfs_mounts="$(get_rootfs_mounts)"
	for mount in ${SPECIAL_MOUNTS[@]}; do
		echo "$rootfs_mounts" | grep -q "/$mount" && $sudo umount -R "$rootfs_dir"/$mount
	done
}
umount_rootfs() {
	[ -e "$rootfs_dir" ] || return

	local rootfs_mounts="$(get_rootfs_mounts)"
	if [ "$rootfs_mounts" ]; then
		if [ "$backend" != "systemd-nspawn" ]; then
			umount_rootfs_special
			rootfs_mounts="$(get_rootfs_mounts)"
		fi
		for mount in $rootfs_mounts; do
			$sudo umount "$mount"
		done
	fi
	$sudo rm -r "$rootfs_dir"
}
unpack_rootfs() {
	log "Unpacking rootfs tarball..."
	umount_rootfs
	mkdir -p "$rootfs_dir"
	$sudo tar xfp "$tarball_dir/$rootfs_tarball" -C "$rootfs_dir"
	log "Rootfs size: $($sudo du -sh "$rootfs_dir" | awk '{print $1}')"
}
setup_pkgcache() {
	[ "$pkgcache_dir" ] || return 0

	log "Preparing package cache for use..."
	[ -e "$pkgcache_dir" ] || mkdir -p "$pkgcache_dir"
	$sudo mkdir "$rootfs_dir"/pkgcache
	$sudo mount --bind "$pkgcache_dir" "$rootfs_dir"/pkgcache
	rootfs_echo "cachedir=/pkgcache" /etc/xbps.d/pkgcache.conf
}
run_on_rootfs() {
	$sudo $chroot "$rootfs_dir" $@ || error "Something went wrong with the bootstrap process!"
}
run_on_rootfs_shell() {
	$sudo $chroot "$rootfs_dir" /bin/bash -c "$1" || error "Something went wrong with the bootstrap process!"
}
run_setup() {
	log "Running $1 rootfs setup..."
	run_on_rootfs /setup.sh $1
}
chroot_setup() {
	for mount in ${SPECIAL_MOUNTS[@]}; do
		$sudo mount --rbind /$mount "$rootfs_dir"/$mount
		$sudo mount --make-rslave "$rootfs_dir"/$mount
	done

	if [ "$qemu_arch" ]; then
		local binfmt_list="$(update-binfmts --display)"
		[ "$binfmt_list" ] || error "Please re-check your binfmt-support setup!"
		$sudo cp $(cmd_path qemu-$qemu_arch-static) "$rootfs_dir"/usr/bin/
	fi
}
# Write content ($1) to a file ($2) on the rootfs.
write_conf() {
	[ "$1" ] || return 0

	log "Writing $2 under $rootfs_dir..."
	rootfs_echo "${1::-2}" $2
}
dns_setup() {
	if [ ${#dns[@]} -eq 0 ]; then
		if [ "$backend" != "systemd-nspawn" ]; then
			log "Copying /etc/resolv.conf from host under $rootfs_dir..."
			$sudo cp -L /etc/resolv.conf "$rootfs_dir"/etc/
		fi
		return
	fi

	[ "$backend" = "systemd-nspawn" ] && chroot+=" --resolv-conf=off"

	local resolv_conf="# Generated by Void Bootstrap
"
	for entry in ${dns[@]}; do
		resolv_conf+="nameserver $entry\n"
	done
	write_conf "$resolv_conf" /etc/resolv.conf
}
mkrootfs_conf_setup() {
	local mkrootfs_conf=""
	for pkg in ${ignorepkg[@]}; do
		mkrootfs_conf+="ignorepkg=$pkg\n"
	done
	for pattern in ${noextract[@]}; do
		mkrootfs_conf+="noextract=$pattern\n"
	done
	write_conf "$mkrootfs_conf" /etc/xbps.d/mkrootfs.conf
}
users_conf_setup() {
	local users_conf=""
	for user in "${users[@]}"; do
		local fields=()
		IFS=':' read -ra fields <<< "$user"
		usernames+=(${fields[0]})
		users_conf+="$user\n"
	done
	write_conf "$users_conf" /users.conf
}
prepare_bootstrap() {
	if [ "$backend" = "systemd-nspawn" ]; then
		if [ "$qemu_arch" ]; then
			systemctl -q is-active systemd-binfmt || $sudo systemctl start systemd-binfmt
		fi
		chroot="systemd-nspawn -q --timezone=off"
	else
		chroot_setup
		chroot="chroot"
	fi

	dns_setup
	[ "$backend" = "systemd-nspawn" ] && chroot+=" -D"
	mkrootfs_conf_setup
	users_conf_setup

	rm_pkgs="${rm_pkgs[@]}"
	(( ${#noextract[@]}+${#rm_files[@]} > 0 )) \
		&& rm_files="${noextract[@]} ${rm_files[@]}" \
		|| rm_files=""
	base_pkgs="${base_pkgs[@]}"
	extra_install_pkgs="${extra_install_pkgs[@]}"
	enable_sv="${enable_sv[@]}"
	disable_sv="${disable_sv[@]}"
	usernames="${usernames[@]}"
	users_groups_common="${users_groups_common[@]}"
	users_groups_common="${users_groups_common// /,}"
	$sudo cp "$base_dir"/setup.sh.in "$rootfs_dir"/setup.sh
	$sudo sed -i "$rootfs_dir"/setup.sh \
		-e "s|@COLOR_GREEN@|$(escape_color GREEN)|g" \
		-e "s|@COLOR_BLUE@|$(escape_color BLUE)|g" \
		-e "s|@COLOR_RED@|$(escape_color RED)|g" \
		-e "s|@COLOR_RESET@|$(escape_color RESET)|g" \
		-e "s|@DEF_MIRROR@|$DEF_MIRROR|g" \
		-e "s|@MIRROR@|$mirror|g" \
		-e "s|@RM_PKGS@|$rm_pkgs|g" \
		-e "s|@RM_FILES@|$rm_files|g" \
		-e "s|@BASE_PKGS@|$base_pkgs|g" \
		-e "s|@EXTRA_PKGS@|$extra_install_pkgs|g" \
		-e "s|@ENABLE_SV@|$enable_sv|g" \
		-e "s|@DISABLE_SV@|$disable_sv|g" \
		-e "s|@HOSTNAME@|$hostname|g" \
		-e "s|@USERNAMES@|$usernames|g" \
		-e "s|@USERS_PW_DEFAULT@|$users_pw_default|g" \
		-e "s|@USERS_PW_ENCRYPTION@|${users_pw_encryption^^}|g" \
		-e "s|@USERS_GROUPS_COMMON@|$users_groups_common|g" \
		-e "s|@USERS_SHELL_DEFAULT@|$users_shell_default|g" \
		-e "s|@USERS_SUDO_ASKPASS@|$users_sudo_askpass|g" \
		-e "s|@PERMIT_ROOT_LOGIN@|$permit_root_login|g"
	$sudo chmod +x "$rootfs_dir"/setup.sh

	copy_script custom
}
extra_pkgs_setup() {
	if [ ${#extra_build_pkgs[@]} -gt 0 ]; then
		setup_xbps_static
		setup_void_packages
		$build_extra_pkgs && build_packages
	fi

	[ "$extra_install_pkgs" ] || return 0 # no extra pkgs to install -> don't setup local repo

	local binpkgs="$XBPS_DISTDIR/hostdir/binpkgs"
	if [ ! -e "$binpkgs" ]; then
		warn "'$binpkgs' doesn't exist; please configure your extra_build_pkgs array!"
		return
	fi

	local arch_prefix="${arch}${musl_suffix}" # e.g. "aarch64-musl"
	local repodir="$binpkgs" # e.g. "void-packages/hostdir/binpkgs/packages"
	local reposuffix # e.g. "/somainline"
	if [ "$void_packages_branch" != "master" ]; then
		reposuffix="/$void_packages_branch"
		repodir+="$reposuffix"
	fi
	if [ ! -e "$repodir/$arch_prefix-repodata" ]; then
		warn "Repo data for $arch_prefix under $repodir not found; skipping local repo..."
		return
	fi

	$sudo mkdir "$rootfs_dir"/packages
	$sudo mount --bind "$binpkgs" "$rootfs_dir"/packages
	rootfs_echo "repository=/packages$reposuffix" /etc/xbps.d/localrepo.conf
}
extra_pkgs_only_setup() {
	[ ${#extra_pkg_steps_only[@]} -gt 0 ] || return 0

	local build=false check=false
	[[ " ${extra_pkg_steps_only[*]} " = *" build "* ]] && build=true
	[[ " ${extra_pkg_steps_only[*]} " = *" check "* ]] && check=true
	[ ${#extra_build_pkgs[@]} -ne 0 ] || error "No extra packages to build/check specified!"

	if $check; then
		build_extra_pkgs=false
		extra_pkgs_setup
		check_pkg_updates
	fi
	if $build; then
		if $build_extra_pkgs; then
			extra_pkgs_setup
		else
			build_packages
		fi
	fi
	exit 0
}
apply_overlays() {
	[ ${#overlays[@]} -gt 0 ] || return 0

	#log "Applying ${#overlays[@]} enabled overlay(s)..."
	local overlay="$base_dir/overlay"
	for folder in ${overlays[@]}; do
		if [[ ! -d "$overlay/$folder" || $(ls -1 "$overlay/$folder" | wc -l) -eq 0 ]]; then
			warn "Overlay folder \"$folder\" either doesn't exist or is empty; ignoring..."
			continue
		fi

		log "Applying enabled overlay $folder..."
		$sudo cp -r "$overlay/$folder"/* "$rootfs_dir"

		if [ -e "$rootfs_dir"/deploy_host.sh ]; then
			(. "$rootfs_dir"/deploy_host.sh) || error "Failed to run deploy_host.sh!"
			$sudo rm "$rootfs_dir"/deploy_host.sh
		fi
		if [ -e "$rootfs_dir"/deploy.sh ]; then
			$sudo sed '1 a . /setup.sh' -i "$rootfs_dir"/deploy.sh
			$sudo chmod +x "$rootfs_dir"/deploy.sh
			run_on_rootfs /deploy.sh
			$sudo rm "$rootfs_dir"/deploy.sh
		fi
		if [ -e "$rootfs_dir"/home/ALL ]; then
			for user in $usernames; do
				# TODO: also cp to /root?
				[ "$user" = "root" ] && continue
				$sudo cp -r "$rootfs_dir"/home/ALL/. "$rootfs_dir"/home/$user/
			done
			$sudo rm -r "$rootfs_dir"/home/ALL
		fi
	done
}
fix_user_perms() {
	[ $user_count -gt 0 ] || return 0

	log "Fixing home folder ownership for $user_count user(s)..."
	for user in $usernames; do
		[ "$user" = "root" ] && continue
		run_on_rootfs_shell "chown -R $user: /home/$user"
	done
}
teardown_pkgcache() {
	[ -e "$rootfs_dir"/pkgcache ] || return 0

	$sudo rm "$rootfs_dir"/etc/xbps.d/pkgcache.conf
	$sudo umount "$rootfs_dir"/pkgcache
	$sudo rmdir "$rootfs_dir"/pkgcache
	$sudo chown -R $USER: "$pkgcache_dir"

	if ! cmd_exists python3; then
		warn "Not attempting to clean old version copies from cached packages as python3 wasn't found!"
		return
	fi

	# FIXME: This appears to not work outside chroot(?) with static xbps
	setup_xbps_static
	log "Cleaning old version copies of cached packages..."
	[ -e "$pkgcache_dir"/prune.py ] \
		|| wget https://raw.githubusercontent.com/JamiKettunen/xbps-cache-prune/master/xbps-cache-prune.py \
			-t 3 --show-progress -qO "$pkgcache_dir"/prune.py
	# -d false
	python3 "$pkgcache_dir"/prune.py -c "$pkgcache_dir" -n 3 || :
}
teardown_extra_pkgs() {
	[ -e "$rootfs_dir"/packages ] || return 0

	$sudo rm "$rootfs_dir"/etc/xbps.d/localrepo.conf
	$sudo umount "$rootfs_dir"/packages
	$sudo rmdir "$rootfs_dir"/packages
}
finalize_setup() {
	$sudo rm "$rootfs_dir"/setup.sh
	teardown_pkgcache
	teardown_extra_pkgs
	teardown_custom_packages
	fix_user_perms

	if [ "$backend" != "systemd-nspawn" ]; then
		umount_rootfs_special
		[ "$qemu_arch" ] && $sudo rm -f "$rootfs_dir"/usr/bin/qemu-$qemu_arch-static
	fi
	[ ${#overlays[@]} -gt 0 ] && $sudo find "$rootfs_dir" -type f -name '.keep' -delete
	local rootfs_size="$($sudo du -sh "$rootfs_dir" | awk '{print $1}')" # e.g. "447M"
	log "Rootfs creation done; final size: $rootfs_size"
}
create_image() {
	[ "$img_size" != "0" ] || return 0

	log "Creating $img_size ext4 rootfs image..."
	[ -e images ] || mkdir -p images
	rootfs_img="images/${img_name_format/\%a/$arch$musl_suffix}" # e.g. "aarch64-musl-rootfs-2021-05-24.img"
	# TODO: F2FS / XFS filesystem support
	mount | grep -q "$base_dir/tmpmnt" && $sudo umount tmpmnt
	fallocate -l $img_size "$rootfs_img"
	mkfs.ext4 -m 1 -F "$rootfs_img" #&> /dev/null
	mkdir -p tmpmnt
	$sudo mount "$rootfs_img" tmpmnt

	log "Moving Void Linux installation to $rootfs_img..."
	$sudo mv "$rootfs_dir"/* tmpmnt/
	$sudo umount tmpmnt
	$sudo rmdir tmpmnt
	umount_rootfs

	log "Resizing $rootfs_img to be as small as possible..."
	e2fsck -fy "$rootfs_img" #&>/dev/null
	resize2fs -M "$rootfs_img" #&>/dev/null

	if [ "$img_compress" = "xz" ]; then
		log "Creating $rootfs_img.xz using $(nproc) threads, please wait..."
		xz -f --threads=0 "$rootfs_img"
		rootfs_img+=".xz"
	elif [ "$img_compress" = "gz" ]; then
		local gz=""
		if cmd_exists pigz; then
			log "Creating $rootfs_img.gz using $(nproc) threads, please wait..."
			gz="pigz"
		else
			log "Creating $rootfs_img.gz using 1 thread, please wait..."
			gz="gzip"
		fi
		$gz -nf9 "$rootfs_img"
		rootfs_img+=".gz"
	fi

	log "All done! Final image size: $(du -h "$rootfs_img" | awk '{print $1}')"
}
cleanup() {
	if ${custom_packages_setup:-false}; then
		teardown_custom_packages
	fi
}

# Script
#########
trap cleanup EXIT
run_script pre
parse_args $@
config_prep
check_deps
print_config
extra_pkgs_only_setup
fetch_rootfs
unpack_rootfs
setup_pkgcache
prepare_bootstrap
run_setup stage1
extra_pkgs_setup
run_setup stage2
apply_overlays
finalize_setup
create_image
run_script post
