#!/usr/bin/env bash
set -e
#set -x # Debug

# Constants
############
SUPPORTED_ARCHES=(aarch64 armv6l armv7l x86_64 i686)
DEF_MIRROR="https://alpha.de.repo.voidlinux.org"
COLOR_GREEN="\e[32m"
COLOR_BLUE="\e[36m"
COLOR_RED="\e[91m"
COLOR_YELLOW="\e[33m"
COLOR_RESET="\e[0m"

# Runtime vars
###############
config="config.custom.sh"
base_dir="$(readlink -f "$(dirname "$0")")"
host_arch="$(uname -m)" # e.g. "x86_64"
qemu_arch="" # e.g. "aarch64" / "arm"
rootfs_dir="" # e.g. "/tmp/void-bootstrap/rootfs"
rootfs_tarball="" # e.g. "void-aarch64-musl-ROOTFS-20210218.tar.xz"
tarball_dir="$base_dir/tarballs"
build_extra_pkgs=true
missing_deps=()
user_count=0
sudo="sudo" # unset if running as root

# Functions
############
die() { echo -e "$1" 1>&2; exit 1; }
usage() { die "usage: $0 [-c alternate_config.sh] [-B] [-N]"; }
error() { die "${COLOR_RED}ERROR: $1${COLOR_RESET}"; }
log() { echo -e "${COLOR_BLUE}>>${COLOR_RESET} $1"; }
warn() { echo -e "${COLOR_YELLOW}WARN: $1${COLOR_RESET}" 1>&2; }
cmd_exists() { command -v $1 >/dev/null; }
escape_color() { local c="COLOR_$1"; printf '%q' "${!c}" | sed "s/^''$//"; }
rootfs_echo() { echo -e "$1" | $sudo tee "$rootfs_dir/$2" >/dev/null; }
run_script() { [ -e "$base_dir/mkrootfs.$1.sh" ] && . "$base_dir/mkrootfs.$1.sh" || :; }
copy_script() { [ -e "$base_dir/mkrootfs.$1.sh" ] && $sudo cp "$base_dir/mkrootfs.$1.sh" "$rootfs_dir"/ || :; }
parse_args() {
	while getopts ":c:NB" OPT; do
		case "$OPT" in
			c) config=$OPTARG ;;
			B) build_extra_pkgs=false ;;
			N) unset COLOR_GREEN COLOR_BLUE COLOR_RED COLOR_RESET ;;
			*) usage ;;
		esac
	done
}
config_prep() {
	[ $EUID -eq 0 ] && unset sudo
	. config.sh
	[ -r "$config" ] && . "$config" || config="config.sh"
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
	[ "$work_dir" ] || work_dir="."
	work_dir="$(readlink -f "$work_dir")"
	rootfs_dir="$work_dir/rootfs"
	[ -d "$rootfs_dir" ] || mkdir -p "$rootfs_dir"
	[ "$mirror" ] || mirror="$DEF_MIRROR"
	[ "$img_compress" ] || img_compress="none"
	user_count=$(printf '%s\n' "${users[@]}" | grep -v ^root | wc -l)
	[[ $((${#extra_build_pkgs[@]}+${#extra_install_pkgs[@]})) -gt 0 ]] || build_extra_pkgs=false
}
check_deps() {
	runtime_deps=(systemd-nspawn wget mkfs.ext4 $sudo)
	[ "$qemu_arch" ] && runtime_deps+=(qemu-$qemu_arch-static)
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
	if $musl; then
		rootfs_match="$arch-musl-ROOTFS" # musl
	else
		rootfs_match="$arch-ROOTFS" # glibc
	fi
	rootfs_tarball="$(wget "$mirror/live/current/" -t 3 -qO - | grep $rootfs_match | cut -d'"' -f2)"
	log "Latest tarball: $rootfs_tarball"
	[ "$rootfs_tarball" ] || die "Please check your arch ($arch) and mirror ($mirror)!"
	local tarball_url="$mirror/live/current/$rootfs_tarball"
	[ -e "$tarball_dir/$rootfs_tarball" ] && return

	log "Downloading rootfs tarball..."
	mkdir -p "$tarball_dir"
	wget "$tarball_url" -t 3 --show-progress -qO "$tarball_dir/$rootfs_tarball"

	log "Verifying tarball SHA256 checksum..."
	local checksum="$(sha256sum "$tarball_dir/$rootfs_tarball" | awk '{print $1}')"
	wget "$mirror/live/current/sha256sum.txt" -t 3 -qO - | grep -q "$rootfs_tarball.*$checksum\$" && return

	rm "$tarball_dir/$rootfs_tarball"
	die "Rootfs tarball checksum verification failed; please try again!"
}
umount_rootfs() {
	[ -e "$rootfs_dir" ] || return

	local rootfs_mounts="$(grep "$rootfs_dir" /proc/mounts | awk '{print $2}' || :)"
	if [ "$rootfs_mounts" ]; then
		for mount in $rootfs_mounts; do
			#echo "  unmounting $mount..."
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
	[ "$pkgcache_dir" ] || return

	log "Preparing package cache for use..."
	[ -e "$pkgcache_dir" ] || mkdir -p "$pkgcache_dir"
	$sudo mkdir "$rootfs_dir"/pkgcache
	$sudo mount --bind "$pkgcache_dir" "$rootfs_dir"/pkgcache
	rootfs_echo "cachedir=/pkgcache" /etc/xbps.d/pkgcache.conf
}
run_on_rootfs() {
	$sudo systemd-nspawn -D "$rootfs_dir" -q $@ \
		|| error "Something went wrong with the bootstrap process!"
}
run_setup() {
	log "Running $1 rootfs setup..."
	run_on_rootfs /setup.sh $1
}
prepare_bootstrap() {
	# FIXME: also do sys,dev,proc mounts, resolv.conf copy & timezone symlink with proot!

	local mkrootfs_conf=""
	for pkg in ${ignorepkg[@]}; do
		mkrootfs_conf+="ignorepkg=$pkg\n"
	done
	for pattern in ${noextract[@]}; do
		mkrootfs_conf+="noextract=$pattern\n"
	done
	if [ "$mkrootfs_conf" ]; then
		log "Writing /etc/xbps.d/mkrootfs.conf under $rootfs_dir..."
		rootfs_echo "${mkrootfs_conf::-2}" /etc/xbps.d/mkrootfs.conf
	fi

	printf '%s\n' "${users[@]}" | grep -q ^root || users+=(root)
	local users_conf=""
	for user in "${users[@]}"; do
		users_conf+="$user\n"
	done
	log "Writing /users.conf under $rootfs_dir..."
	rootfs_echo "${users_conf::-2}" /users.conf

	rm_pkgs="${rm_pkgs[@]}"
	(( ${#noextract[@]}+${#rm_files[@]} > 0 )) \
		&& rm_files="${noextract[@]} ${rm_files[@]}" \
		|| rm_files=""
	base_pkgs="${base_pkgs[@]}"
	extra_install_pkgs="${extra_install_pkgs[@]}"
	enable_sv="${enable_sv[@]}"
	disable_sv="${disable_sv[@]}"
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
		-e "s|@USERS_PW_DEFAULT@|$users_pw_default|g" \
		-e "s|@USERS_PW_ENCRYPTION@|${users_pw_encryption^^}|g" \
		-e "s|@USERS_GROUPS_COMMON@|$users_groups_common|g" \
		-e "s|@USERS_SHELL_DEFAULT@|$users_shell_default|g" \
		-e "s|@USERS_SUDO_ASKPASS@|$users_sudo_askpass|g" \
		-e "s|@PERMIT_ROOT_LOGIN@|$permit_root_login|g"
	$sudo chmod +x "$rootfs_dir"/setup.sh

	copy_script custom
}
setup_xbps_static() {
	cmd_exists xbps-uhelper && return
	[ -e xbps-static ] || mkdir xbps-static

	local checksums="$(wget "$mirror/static/sha256sums.txt" -t 3 -qO -)" checksum=""
	local xbps_tarball="xbps-static-latest.${host_arch}-musl.tar.xz"
	local fetch=true

	# don't fetch in case already up-to-date
	if [ -f "$tarball_dir/$xbps_tarball" ]; then
		checksum="$(sha256sum "$tarball_dir/$xbps_tarball" | awk '{print $1}')"
		echo "$checksums" | grep -q "$checksum.*$xbps_tarball\$" && fetch=false
	fi

	if $fetch; then
		log "Fetching latest static xbps binaries for $host_arch..."
		wget "$mirror/static/$xbps_tarball" -t 3 --show-progress -qO "$tarball_dir/$xbps_tarball"
		checksum="$(sha256sum "$tarball_dir/$xbps_tarball" | awk '{print $1}')"
		if ! echo "$checksums" | grep -q "$checksum.*$xbps_tarball\$"; then
			rm "$tarball_dir/$xbps_tarball"
			error "XBPS static tarball checksum verification failed; please try again!"
		fi

		[ -e xbps-static/usr ] && rm -rf xbps-static/{usr,var}/ # cleanup
		tar xf "$tarball_dir/$xbps_tarball" -C xbps-static # unpack
	fi

	export PATH=$base_dir/xbps-static/usr/bin:$PATH
}
build_packages() {
	pushd void-packages >/dev/null

	local masterdir="masterdir"
	if $musl; then
		local musl_suffix="-musl"
		masterdir+="$musl_suffix"
	fi
	local host_target="${host_arch}${musl_suffix}"
	[ "$host_arch" != "$arch" ] && local cross_target="${arch}${musl_suffix}"
	log "Void package build configuration:

  masterdir:    $masterdir
  host target:  $host_target
  cross target: $cross_target
  packages:     $(fold_offset 16 "${extra_build_pkgs[@]}")
  chroot:       $build_chroot_preserve
"
	# ${#extra_build_pkgs[@]}

	# chroot setup
	if [ -e $masterdir ]; then
		if [[ -z "$build_chroot_preserve" || "$build_chroot_preserve" = "none" ]]; then
			log "Removing existing build chroot..."
			$sudo rm -r $masterdir
		elif [ "$build_chroot_preserve" = "ccache" ]; then
			log "Cleaning existing build chroot (without removing ccache)..."
			./xbps-src -m $masterdir zap
		else # all
			log "Updating existing build chroot..."
			./xbps-src -m $masterdir bootstrap-update
		fi
	fi
	if [ ! -e $masterdir/bin/sh ]; then
		log "Creating new $host_target build chroot..."
		./xbps-src -m $masterdir binary-bootstrap $host_target
	fi

	# xbps-src configuration
	local xbps_src_config="# as configured in Void Bootstrap's config.sh"
	add_if_set() { for cfg in $@; do cfg="XBPS_$cfg"; [ "${!cfg}" ] && xbps_src_config+="\n$cfg=\"${!cfg}\""; done; }
	add_if_set ALLOW_RESTRICTED MAKEJOBS CCACHE # CHECK_PKGS
	local write_config=true
	if [ -e etc/conf ]; then
		local file_sum="$(sha256sum etc/conf | awk '{print $1}')"
		local new_sum="$(echo -e "$xbps_src_config" | sha256sum | awk '{print $1}')"
		[ "$file_sum" = "$new_sum" ] && write_config=false
	fi
	$write_config && echo -e "$xbps_src_config" > etc/conf

	# check updates
	#log "Checking updates for packages which will be built..."
	#local updates=""
	#for pkg in ${extra_build_pkgs[@]}; do
	#	updates+="$(./xbps-src update-check $pkg)"
	#done
	#if [ "$updates" ]; then
	#	warn "Some packages (listed below) appear to be out of date; continuing anyway..."
	#	echo -e "$updates"
	#fi

	# build packages
	# TODO: Make sure somehow that we don't keep building packages that are already up-to-date?
	# - Do this by checking matching version against /packages/**/*.xbps?
	# - Perhaps store a checksum of srcpkgs/$pkg and check against later?
	for pkg in ${extra_build_pkgs[@]}; do
		if [ "$cross_target" ]; then
			log "Cross-compiling extra package '$pkg' for $cross_target..."
			./xbps-src -m $masterdir -a $cross_target pkg $pkg
		else
			log "Compiling extra package '$pkg' for $host_target..."
			./xbps-src -m $masterdir pkg $pkg
		fi
	done

	popd >/dev/null
}
extra_pkgs_setup() {
	if [ ${#extra_build_pkgs[@]} -gt 0 ]; then
		setup_xbps_static

		if [ ! -e void-packages ]; then
			log "Creating a local clone of $void_packages..."
			git clone $void_packages
		else
			git -C void-packages pull \
				|| warn "Couldn't pull updates to void-packages clone automatically; ignoring..."
		fi

		$build_extra_pkgs && build_packages
	fi

	if [ "$extra_install_pkgs" ]; then
		local binpkgs="void-packages/hostdir/binpkgs"
		if [ -e $binpkgs ]; then
			$sudo mkdir "$rootfs_dir"/packages
			$sudo mount --bind $binpkgs "$rootfs_dir"/packages
		else
			warn "'$binpkgs' doesn't exist; please configure your extra_build_pkgs array!"
		fi
	fi
}
apply_overlays() {
	[ ${#overlays[@]} -gt 0 ] || return 0

	log "Applying ${#overlays[@]} enabled overlay(s)..."
	local overlay="$base_dir/overlay"
	for folder in ${overlays[@]}; do
		if [[ ! -d "$overlay/$folder" || $(ls -1 "$overlay/$folder" | wc -l) -eq 0 ]]; then
			warn "Overlay folder \"$folder\" either doesn't exist or is empty; ignoring..."
			continue
		fi

		$sudo cp -a "$overlay/$folder"/* "$rootfs_dir"

		if [ -e "$rootfs_dir"/deploy.sh ]; then
			$sudo sed '1 a . /setup.sh' -i "$rootfs_dir"/deploy.sh
			$sudo chmod +x "$rootfs_dir"/deploy.sh
			run_on_rootfs /deploy.sh
			$sudo rm "$rootfs_dir"/deploy.sh
		fi
		if [ -e "$rootfs_dir"/deploy_host.sh ]; then
			. "$rootfs_dir"/deploy_host.sh
			$sudo rm "$rootfs_dir"/deploy_host.sh
		fi

		# FIXME: Make sure /packages from build results is umounted etc before this is done!
		#if [ -d "$rootfs_dir"/packages ]; then
		#	log "TODO: Install overlay packages from /packagess/*.xbps!"
		#	$sudo rm -r "$rootfs_dir"/packages
		#fi
	done
}
finalize_setup() {
	$sudo rm "$rootfs_dir"/setup.sh
	if [ -e "$rootfs_dir"/pkgcache ]; then
		$sudo rm "$rootfs_dir"/etc/xbps.d/pkgcache.conf
		$sudo umount "$rootfs_dir"/pkgcache
		$sudo rmdir "$rootfs_dir"/pkgcache
		$sudo chown -R $USER: "$pkgcache_dir"

		if cmd_exists python3; then
			# FIXME: This appears to not work outside chroot(?) with static xbps
			setup_xbps_static
			log "Cleaning old version copies of cached packages..."
			[ -e "$pkgcache_dir"/prune.py ] \
				|| wget https://raw.githubusercontent.com/JamiKettunen/xbps-cache-prune/master/xbps-cache-prune.py \
					-t 3 --show-progress -qO "$pkgcache_dir"/prune.py
			# -d false
			python3 "$pkgcache_dir"/prune.py -c "$pkgcache_dir" -n 3 || :
		else
			warn "Not attempting to clean old version copies from cached packages as python3 wasn't found!"
		fi
	fi
	if [ -e "$rootfs_dir"/packages ]; then
		$sudo umount "$rootfs_dir"/packages
		$sudo rmdir "$rootfs_dir"/packages
	fi

	local rootfs_size="$($sudo du -sh "$rootfs_dir" | awk '{print $1}')" # e.g. "447M"
	log "Rootfs creation done; final size: $rootfs_size"
}
create_image() {
	log "Creating $img_size ext4 rootfs image..."
	[ -e images ] || mkdir -p images
	rootfs_img="images/${rootfs_match,,}${img_name_extra}-$(date +'%Y-%m-%d').img" # e.g. "aarch64-musl-rootfs-2021-05-24.img"
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

# Script
#########
run_script pre
parse_args $@
config_prep
check_deps
print_config
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
