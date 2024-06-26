#!/usr/bin/env bash
set -e
#set -x # Debug

# Constants
############
SUPPORTED_ARCHES=(aarch64 armv6l armv7l x86_64 i686)
SPECIAL_MOUNTS=(sys dev proc)
DEF_MIRROR="https://repo-default.voidlinux.org"
BINFMT_PROCFS="/proc/sys/fs/binfmt_misc"
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
profiles=("$base_dir")
profiles_exclude=()
top_profile="$base_dir"
host_arch="$(uname -m)" # e.g. "x86_64"
qemu_arch="" # e.g. "aarch64" / "arm"
musl_suffix="" # e.g. "-musl"
rootfs_match="" # e.g. "aarch64-musl-ROOTFS"
rootfs_dir="" # e.g. "/tmp/void-bootstrap/rootfs"
wget="" # e.g. "wget2" or "wget"
wget_progress_args=() # e.g. "--progress=bar --force-progress" or "--show-progress"
rootfs_tarball="" # e.g. "void-aarch64-musl-ROOTFS-20210218.tar.xz"
tarball_dir="$base_dir/tarballs"
chroot="" # e.g. "chroot" or "systemd-nspawn -q -D"
build_extra_pkgs=true
extra_pkg_steps_only=()
user_count=0
usernames=()

# Functions
############
die() { echo -e "$1" 1>&2; exit 1; }
usage() {
	die "void-bootstrap - Customize & create Void Linux rootfs images.

USAGE:
    $0 [FLAGS] [OPTIONS]...

FLAGS:
    -B, --no-build-pkgs  Don't build any configured extra_build_pkgs array packages
    -u, --check-updates-only
                         Only check updates to configured extra_build_pkgs array packages
                         instead of creating a rootfs
    -b, --build-pkgs-only
                         Only build configured extra_build_pkgs array packages instead of
                         creating a rootfs
    -t, --teardown-void-packages
                         Only cleanup all non-committed changes from XBPS_DISTDIR instead
                         of creating a rootfs
    -f, --force-rebuild  Force rebuild of configured extra_build_pkgs array packages
                         even if an up-to-date local package is found
    -N, --no-color       Don't add color to log messages, done automatically when piping
                         the output from this script
    -h, --help           Show this screen

OPTIONS:
    -a, --arch    Set target rootfs architecture, supported choices:
                  ${SUPPORTED_ARCHES[*]}
    -c, --config  Choose an alternative config file, defaults to config.custom.sh
    -m, --musl    Choose whether or not to use musl over glibc as the C standard library,
                  true or false
    -p, --add-profile-dir
                  Add a profile directory to being considered when looking for overlays
                  or packages to build
    -P, --exclude-profile-dir
                  Reverse of --add-profile-dir"
}
error() { die "${COLOR_RED}ERROR: $1${COLOR_RESET}"; }
log() { echo -e "${COLOR_BLUE}>>${COLOR_RESET} $1"; }
warn() { echo -e "${COLOR_YELLOW}WARN: $1${COLOR_RESET}" 1>&2; }
cmd_path() { command -v $1; }
cmd_exists() { cmd_path $1 >/dev/null; }
escape_color() { local c="COLOR_$1"; printf '%q' "${!c}" | sed "s/^''$//"; }
disable_color() { unset COLOR_GREEN COLOR_BLUE COLOR_RED COLOR_RESET; }
rootfs_echo() { echo -e "$1" | $sudo tee "$rootfs_dir/$2" >/dev/null; }
get_rootfs_mounts() { grep "$rootfs_dir" /proc/mounts | awk '{print $2}' || :; }
run_script() { [ -f "$base_dir/mkrootfs.$1.sh" ] && . "$base_dir/mkrootfs.$1.sh" || :; }
copy_script() { [ -f "$base_dir/mkrootfs.$1.sh" ] && $sudo cp "$base_dir/mkrootfs.$1.sh" "$rootfs_dir"/ || :; }
parse_args() {
	while [ $# -gt 0 ]; do
		case $1 in
			-a|--arch) config_overrides+=("arch=$2"); shift ;;
			-B|--no-build-pkgs) build_extra_pkgs=false ;;
			-b|--build-pkgs-only) build_extra_pkgs=true; extra_pkg_steps_only+=(build) ;;
			-c|--config) config="$2"; shift ;;
			-f|--force-rebuild) config_overrides+=("unset XBPS_PRESERVE_PKGS") ;;
			-m|--musl) config_overrides+=("musl=$2"); shift ;;
			-N|--no-color) disable_color ;;
			-u|--check-updates-only) extra_pkg_steps_only+=(check) ;;
			-t|--teardown-void-packages) extra_pkg_steps_only+=(teardown) ;;
			-p|--add-profile-dir) profiles+=("$2"); shift ;;
			-P|--exclude-profile-dir) profiles_exclude+=("$2"); shift ;;
			*) usage ;;
		esac
		shift
	done
}
config_prep() {
	[ -t 1 ] || disable_color # avoid writing color escape codes to piped stdout
	unset XBPS_DISTDIR
	cd "$base_dir"
	local input_profiles=("${profiles[@]}") profile
	profiles=()
	for profile in "${input_profiles[@]}"; do
		[[ " ${profiles_exclude[*]} " =~ " $profile " ]] && continue
		[[ " ${profiles[*]} " =~ " $profile " ]] && continue # avoid duplicated
		profiles+=("$profile")
		top_profile="$profile"
	done
	[ ${#profiles[@]} -eq 0 ] && error "At least one profile has to be available!"
	. config.sh
	cd "$top_profile"
	[ -r "$config" ] && . "$config" || config="config.sh"
	if [[ "$config" != "config.local.sh" && -r "config.local.sh" ]]; then
		log "Including config.local.sh overrides..."
		. config.local.sh
	fi
	cd "$base_dir"
	if [ $EUID -eq 0 ]; then
		unset sudo
	elif [ -z "$sudo" ]; then
		if cmd_exists sudo; then
			sudo="sudo"
		elif cmd_exists doas; then
			sudo="doas"
		fi
	fi
	for override in "${config_overrides[@]}"; do
		eval "$override" # e.g. "arch=armv7l"
	done
	if ! echo " ${SUPPORTED_ARCHES[*]} " | grep -q " $arch "; then
		local error_msg="Target architecture '$arch' is invalid! Valid choices include:\n\n"
		for arch in "${SUPPORTED_ARCHES[@]}"; do
			error_msg+="   $arch\n"
		done
		error "$error_msg"
	fi
	if [ "$arch" = "i686" ]; then
		$musl && error "$arch doesn't have a musl rootfs variant available!"
	fi
	if [ "$host_arch" != "$arch" ]; then
		case "$arch" in
			"armv"*) qemu_arch="arm" ;;
			"i686") [ "$host_arch" != "x86_64" ] && qemu_arch="i386" ;;
			*) qemu_arch="$arch" ;;
		esac
	fi
	$musl && musl_suffix="-musl"
	rootfs_match="$arch$musl_suffix-ROOTFS" # musl/glibc
	if [ -z "$backend" ]; then
		cmd_exists systemd-nspawn && backend="systemd-nspawn" || backend="chroot"
	fi
	[ "$work_dir" ] || work_dir="$base_dir"
	rootfs_dir="$work_dir/rootfs"
	[ "$mirror" ] || mirror="$DEF_MIRROR"
	[ "$img_compress" ] || img_compress="none"
	if [[ "$img_size" != "0" && ! -c /dev/loop-control ]]; then
		error "Cannot setup rootfs filesystem image due to missing host /dev/loop-control!"
	fi
	user_count=$(printf '%s\n' "${users[@]}" | grep -cv '^root$')
	printf '%s\n' "${users[@]}" | grep -q '^root$' || users+=(root)
	[[ $((${#extra_build_pkgs[@]}+${#extra_install_pkgs[@]})) -gt 0 ]] || build_extra_pkgs=false
	. xbps-env.sh
}
check_deps() {
	local runtime_deps=($backend xz mkfs.ext4 $sudo tar) missing_deps=()
	[[ $EUID -ne 0 && -z "$sudo" ]] && missing_deps+=("(sudo|doas)")
	if cmd_exists wget2; then
		wget="wget2"
		wget_progress_args=(--progress=bar --force-progress)
	elif cmd_exists wget; then
		wget="wget"
		wget_progress_args=(--show-progress)
	else
		missing_deps+=("(wget2|wget)")
	fi
	[ "$img_compress" = "gz" ] && runtime_deps+=(gzip)
	if [ "$qemu_arch" ]; then
		cmd_exists qemu-$qemu_arch-static || cmd_exists qemu-$qemu_arch || \
			missing_deps+=("(qemu-$qemu_arch-static|qemu-$qemu_arch)")
		[[ "$backend" != "systemd-nspawn" && $(find $BINFMT_PROCFS/* 2>/dev/null | wc -l) -eq 0 ]] && runtime_deps+=(update-binfmts)
	fi
	[ ${#extra_build_pkgs[@]} -gt 0 ] && runtime_deps+=(git patch)

	for dep in ${runtime_deps[@]}; do
		cmd_exists $dep || missing_deps+=($dep)
	done
	[ ${#missing_deps[@]} -eq 0 ] && return

	error "${#missing_deps[@]} missing host binaries found:

   ${missing_deps[*]}
"
}
setup_binfmt() {
	[ "$qemu_arch" ] || return 0

	local binfmt_backend="binfmt_misc" binfmt_qemu
	if [ "$backend" = "systemd-nspawn" ]; then
		binfmt_backend="systemd-binfmt"
		if ! systemctl -q is-active systemd-binfmt; then
			$sudo systemctl start systemd-binfmt
			systemctl -q is-active systemd-binfmt || error "Couldn't start 'systemd-binfmt' service; please see 'systemctl status systemd-binfmt'!"
		fi
	fi

	# TODO: detailed error reports on what might be wrong with binfmt_misc
	binfmt_qemu=$(find $BINFMT_PROCFS/* -exec grep -sl "interpreter.*qemu.*$qemu_arch" {} + | head -n1)
	if [ -z "$binfmt_qemu" ] || ! grep -q '^enabled$' $binfmt_qemu; then
		error "Please re-check your $binfmt_backend setup (enabled qemu-$qemu_arch{,-static} interpreter wasn't detected)!"
	fi
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
	echo "Host environment:

  arch:    $host_arch
  sudo:    ${sudo:-none}
  wget:    $wget
  backend: $backend

Rootfs configuration:

  arch:     $arch
  release:  $release
  musl:     $musl
  mirror:   $mirror
  users:    $user_count
  hostname: $hostname"
if [ "$pkgcache_dir" ]; then
	echo "  pkgcache: $pkgcache_dir"
else
	echo "  pkgcache: none"
fi
echo "  profiles: $(fold_offset 12 "${profiles[*]}")"
if [ ${#overlays[@]} -gt 0 ]; then
	echo "  overlays: $(fold_offset 12 "${overlays[*]}")"
else
	echo "  overlays: none"
fi
echo "  work:     $work_dir
  config:   $config

Extra packages:
"
if [ ${#extra_install_pkgs[@]} -gt 0 ]; then
	echo "  build:    $build_extra_pkgs
  install:  $(fold_offset 12 "${extra_install_pkgs[*]}")"
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
	rootfs_tarball="$($wget "$mirror/live/$release/" -t 3 -qO - | grep $rootfs_match | cut -d'"' -f2)"
	log "Latest tarball: $rootfs_tarball"
	[ "$rootfs_tarball" ] || error "Please check your arch ($arch) and mirror ($mirror)!"
	local tarball_url="$mirror/live/$release/$rootfs_tarball"
	[ -f "$tarball_dir/$rootfs_tarball" ] && return

	log "Downloading rootfs tarball..."
	mkdir -p "$tarball_dir"
	$wget "$tarball_url" -t 3 "${wget_progress_args[@]}" -qO "$tarball_dir/$rootfs_tarball"

	log "Verifying tarball SHA256 checksum..."
	local filenames=() checksums=""
	for file in sha256sums sha256sum sha256; do
		checksums="$($wget "$mirror/live/$release/$file.txt" -t 3 -qO - || :)"
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
		echo "$rootfs_mounts" | grep -q "/$mount" && $sudo umount -Rl "$rootfs_dir"/$mount
	done
}
umount_rootfs() {
	[ -d "$rootfs_dir" ] || return 0

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
start_sudo_timer() {
	# FIXME: figure out a working implementation for "doas"
	$sudo_timer || return 0
	[ "$sudo" = "sudo" ] || return 0 # not needed, running as root or using e.g. "doas"

	log "Starting $sudo background timer to prevent repeated password prompts..."
	sudo -v
	while true; do
		sudo -v
		sleep 60
		kill -0 "$$" || exit
	done 2>/dev/null &
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
	[ -d "$pkgcache_dir" ] || mkdir -p "$pkgcache_dir"
	$sudo mkdir "$rootfs_dir"/pkgcache
	$sudo mount --bind "$pkgcache_dir" "$rootfs_dir"/pkgcache
	rootfs_echo "cachedir=/pkgcache" /etc/xbps.d/pkgcache.conf
}
run_on_rootfs() {
	$sudo $chroot "$rootfs_dir" "$@" || error "Something went wrong with the bootstrap process!"
}
run_on_rootfs_shell() {
	run_on_rootfs /bin/bash -c "$1"
}
run_setup() {
	log "Running $1 rootfs setup..."
	run_on_rootfs /setup.sh "$1"
}
chroot_setup() {
	for mount in ${SPECIAL_MOUNTS[@]}; do
		$sudo mount --rbind /$mount "$rootfs_dir"/$mount
		$sudo mount --make-rslave "$rootfs_dir"/$mount
	done
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
	for pattern in "${noextract[@]}"; do
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
		chroot="systemd-nspawn -q --console=pipe --timezone=off"
	else
		chroot_setup
		chroot="chroot"
	fi

	dns_setup
	[ "$backend" = "systemd-nspawn" ] && chroot+=" -D"
	mkrootfs_conf_setup
	users_conf_setup

	(( ${#noextract[@]}+${#rm_files[@]} > 0 )) \
		&& rm_files="${noextract[@]} ${rm_files[@]}" \
		|| rm_files=""
	sed \
		-e "s|@COLOR_GREEN@|$(escape_color GREEN)|g" \
		-e "s|@COLOR_BLUE@|$(escape_color BLUE)|g" \
		-e "s|@COLOR_RED@|$(escape_color RED)|g" \
		-e "s|@COLOR_RESET@|$(escape_color RESET)|g" \
		-e "s|@DEF_MIRROR@|$DEF_MIRROR|g" \
		-e "s|@MIRROR@|$mirror|g" \
		-e "s|@RM_PKGS@|${rm_pkgs[*]}|g" \
		-e "s|@RM_FILES@|$rm_files|g" \
		-e "s|@EXTRA_VOID_REPOS@|${extra_void_repos[*]}|g" \
		-e "s|@BASE_PKGS@|${base_pkgs[*]}|g" \
		-e "s|@EXTRA_PKGS@|${extra_install_pkgs[*]}|g" \
		-e "s|@ENABLE_SV@|${enable_sv[*]}|g" \
		-e "s|@DISABLE_SV@|${disable_sv[*]}|g" \
		-e "s|@HOSTNAME@|$hostname|g" \
		-e "s|@USERNAMES@|${usernames[*]}|g" \
		-e "s|@USERS_PW_DEFAULT@|$users_pw_default|g" \
		-e "s|@USERS_PW_ENCRYPTION@|${users_pw_encryption^^}|g" \
		-e "s|@USERS_GROUPS_COMMON@|$(IFS=','; echo "${users_groups_common[*]}")|g" \
		-e "s|@USERS_SHELL_DEFAULT@|$users_shell_default|g" \
		-e "s|@USERS_SUDO_ASKPASS@|$users_sudo_askpass|g" \
		-e "s|@PERMIT_ROOT_LOGIN@|$permit_root_login|g" \
		"$base_dir"/setup.sh.in \
		| $sudo tee "$rootfs_dir"/setup.sh >/dev/null
	$sudo chmod +x "$rootfs_dir"/setup.sh

	copy_script custom
}
extra_pkgs_setup() {
	if [ ${#extra_build_pkgs[@]} -gt 0 ]; then
		setup_xbps_static
		setup_void_packages
		$build_extra_pkgs && build_packages
	fi

	[ ${#extra_install_pkgs[@]} -gt 0 ] || return 0 # no extra pkgs to install -> don't setup local repo

	local binpkgs="$XBPS_DISTDIR/hostdir/binpkgs"
	if [ ! -d "$binpkgs" ]; then
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
	if [ ! -f "$repodir/$arch_prefix-repodata" ]; then
		warn "Repo data for $arch_prefix under $repodir not found; skipping local repo..."
		return
	fi

	$sudo mkdir "$rootfs_dir"/packages
	$sudo mount --bind "$binpkgs" "$rootfs_dir"/packages
	rootfs_echo "repository=/packages$reposuffix" /etc/xbps.d/00-repository-local.conf
}
extra_pkgs_only_setup() {
	[ ${#extra_pkg_steps_only[@]} -gt 0 ] || return 0

	local build=false check=false
	[[ " ${extra_pkg_steps_only[*]} " = *" build "* ]] && build=true
	[[ " ${extra_pkg_steps_only[*]} " = *" check "* ]] && check=true
	if [[ " ${extra_pkg_steps_only[*]} " = *" teardown "* && -d "$XBPS_DISTDIR" ]]; then
		custom_packages_setup=true
		teardown_custom_packages
		exit 0
	fi
	[ ${#extra_build_pkgs[@]} -ne 0 ] || error "No extra packages to build/check specified!"

	unset extra_install_pkgs
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
	local profile_overlays=($(echo "${profiles[@]/%/\/overlays}")) overlay_candidates overlay
	for folder in ${overlays[*]}; do
		overlay_candidates=($(find "${profile_overlays[@]}" -maxdepth 1 -name "$folder" -exec sh -c '[ $(ls -1 $1 2>/dev/null | wc -l) -gt 0 ] && echo $1' shell {} \;))
		case ${#overlay_candidates[@]} in
			0)
				warn "Overlay folder \"$folder\" doesn't exist in any profile or is empty; ignoring..."
				continue
				;;
			1) overlay="${overlay_candidates[0]}" ;;
			*)
				overlay="${overlay_candidates[-1]}"
				warn "Overlay folder \"$folder\" has more than one candidate; picking $overlay..."
				;;
		esac

		# TODO: print from which profile!
		log "Applying enabled overlay $folder..."
		$sudo cp -r "$overlay"/* "$rootfs_dir"

		if [ -f "$rootfs_dir"/deploy_host.sh ]; then
			(. "$rootfs_dir"/deploy_host.sh) || error "Failed to run deploy_host.sh!"
			$sudo rm "$rootfs_dir"/deploy_host.sh
		fi
		if [ -f "$rootfs_dir"/deploy.sh ]; then
			if [ "$(grep '^#!.*bash$' "$rootfs_dir"/deploy.sh)" ]; then
				$sudo sed -ie '1 a . /setup.sh' "$rootfs_dir"/deploy.sh
			fi
			$sudo chmod +x "$rootfs_dir"/deploy.sh
			run_on_rootfs /deploy.sh
			$sudo rm "$rootfs_dir"/deploy.sh
		fi
		if [ -d "$rootfs_dir"/home/ALL ]; then
			for user in ${usernames[*]}; do
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
	for user in ${usernames[*]}; do
		[ "$user" = "root" ] && continue
		run_on_rootfs_shell "chown -R $user: /home/$user"
	done
}
teardown_pkgcache() {
	[ -d "$rootfs_dir"/pkgcache ] || return 0

	$sudo rm "$rootfs_dir"/etc/xbps.d/pkgcache.conf
	$sudo umount "$rootfs_dir"/pkgcache
	$sudo rmdir "$rootfs_dir"/pkgcache
	$sudo chown -R $USER: "$pkgcache_dir"

	if ! cmd_exists python3; then
		warn "Not attempting to clean old version copies from cached packages as python3 wasn't found!"
		return 0
	fi

	setup_xbps_static
	log "Cleaning old version copies of cached packages..."
	[ -f "$pkgcache_dir"/prune.py ] \
		|| $wget https://raw.githubusercontent.com/JamiKettunen/xbps-cache-prune/master/xbps-cache-prune.py \
			-t 3 "${wget_progress_args[@]}" -qO "$pkgcache_dir"/prune.py
	python3 "$pkgcache_dir"/prune.py -c "$pkgcache_dir" -n 2 -d false || :
}
teardown_extra_pkgs() {
	[ -d "$rootfs_dir"/packages ] || return 0

	$sudo rm "$rootfs_dir"/etc/xbps.d/00-repository-local.conf
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
	fi
	[ ${#overlays[@]} -gt 0 ] && $sudo find "$rootfs_dir" -type f -name '.empty' -delete
	local rootfs_size="$($sudo du -sh "$rootfs_dir" | awk '{print $1}')" # e.g. "447M"
	log "Rootfs creation done; final size: $rootfs_size"
}
create_image() {
	[ "$img_size" != "0" ] || return 0

	local images="$top_profile/images" tmpmnt="$top_profile/tmpmnt"
	log "Creating $img_size ext4 rootfs image..."
	[ -d "$images" ] || mkdir -p "$images"
	rootfs_img="$images/${img_name_format/\%a/$arch$musl_suffix}" # e.g. "aarch64-musl-rootfs-2021-05-24.img"
	# TODO: F2FS / XFS filesystem support
	mount | grep -q "$tmpmnt" && $sudo umount "$tmpmnt"
	fallocate -l $img_size "$rootfs_img"
	mkfs.ext4 -m 1 -F "$rootfs_img" #&> /dev/null
	mkdir -p "$tmpmnt"
	$sudo mount "$rootfs_img" "$tmpmnt"

	log "Moving Void Linux installation to $rootfs_img..."
	$sudo mv "$rootfs_dir"/* "$tmpmnt"/
	$sudo umount "$tmpmnt"
	$sudo rmdir "$tmpmnt"
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
reset_dirstack() { pushd -0 >/dev/null && dirs -c; }
cleanup() {
	reset_dirstack
	teardown_pkgcache
	teardown_extra_pkgs
	if ${custom_packages_setup:-false}; then
		teardown_custom_packages
	fi
	umount_rootfs
}

# Script
#########
trap cleanup EXIT
run_script pre
parse_args "$@"
config_prep
check_deps
setup_binfmt
print_config
extra_pkgs_only_setup
fetch_rootfs
start_sudo_timer
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
