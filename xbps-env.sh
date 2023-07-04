#!/bin/bash
update_void_packages_branch() {
	if [[ -z "$void_packages_branch" && -e "$XBPS_DISTDIR" ]]; then
		void_packages_branch="$(git -C "$XBPS_DISTDIR" symbolic-ref --short HEAD)"
	fi
}
xbps_config_prep() {
	masterdir="masterdir$musl_suffix"
	host_target="${host_arch}${musl_suffix}"
	[ "$host_arch" != "$arch" ] && cross_target="${arch}${musl_suffix}" #|| cross_target=""
	build_target="${cross_target:-$host_target}"
	[ "$build_chroot_preserve" ] || build_chroot_preserve="none"
	pkgs_build=(${extra_build_pkgs[@]})
	XBPS_DISTFILES_MIRROR="$mirror"
	[ "$XBPS_DISTDIR" ] || XBPS_DISTDIR="$base_dir/void-packages"
	[[ "$XBPS_DISTDIR" != "/"* ]] && XBPS_DISTDIR="$base_dir/$XBPS_DISTDIR"
	update_void_packages_branch
	custom_packages_setup=${custom_packages_setup:-false}
}
setup_xbps_static() {
	cmd_exists xbps-uhelper && return 0
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
		mkdir -p "$tarball_dir"
		if ! wget "$mirror/static/$xbps_tarball" -t 3 --show-progress -qO "$tarball_dir/$xbps_tarball"; then
			rm "$tarball_dir/$xbps_tarball"
			error "Download of $mirror/static/$xbps_tarball failed!"
		fi
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
setup_xbps_src_conf() {
	local xbps_src_config="# as configured in Void Bootstrap's config.sh"
	while read -r cfg; do
		case "${cfg%%=*}" in
			XBPS_DISTDIR)
				continue ;;
		esac
		xbps_src_config+="\n$cfg"
	done < <((set -o posix; set) | grep '^XBPS_')

	local write_config=true
	if [ -e etc/conf ]; then
		local file_sum="$(sha256sum etc/conf | awk '{print $1}')"
		local new_sum="$(echo -e "$xbps_src_config" | sha256sum | awk '{print $1}')"
		[ "$file_sum" = "$new_sum" ] && write_config=false
	fi
	$write_config && echo -e "$xbps_src_config" > etc/conf || :
}
# Returns void-packages clone status; e.g. "up-to-date", "behind", "ahead" or "diverged"
status_of_void_packages() {
	local a=$1 b=$2 # e.g. master v.s. origin/master
	local base=$(git -C "$XBPS_DISTDIR" merge-base $a $b)
	local aref=$(git -C "$XBPS_DISTDIR" rev-parse $a)
	local bref=$(git -C "$XBPS_DISTDIR" rev-parse $b)

	if [ "$aref" = "$bref" ]; then
		echo up-to-date
	elif [ "$aref" = "$base" ]; then
		echo behind
	elif [ "$bref" = "$base" ]; then # FIXME?
		echo ahead
	else
		echo diverged
	fi
}
update_void_packages() {
	update_void_packages_branch
	if ! $void_packages_shallow; then
		log "Pulling updates to local void-packages clone..."
		git -C "$XBPS_DISTDIR" pull && return

		warn "Couldn't pull updates to void-packages clone; trying shallow method..."
	else
		log "Pulling updates to local void-packages shallow clone..."
		git -C "$XBPS_DISTDIR" fetch --depth 1
	fi

	if [[ "$(git -C "$XBPS_DISTDIR" status -s)" ]]; then
		warn "Local void-packages clone not clean; refusing to automatically update!"
		return
	fi

	local branch="$void_packages_branch"
	local origin="origin/$branch"
	local status="$(status_of_void_packages $branch $origin)"
	case "$status" in
		"up-to-date") return ;;
		"diverged")
			local total_commmits=$(git -C "$XBPS_DISTDIR" rev-list --count HEAD) # e.g. 1 on shallow clones
			if [ $total_commmits -gt 1 ]; then
				warn "Refusing to update diverged $branch with more than one commit to $origin!"
				return
			fi
			;;
		"ahead")
			warn "Refusing to update from $branch to $origin; status: $status"
			return
			;;
	esac

	git -C "$XBPS_DISTDIR" reset --hard $origin
	#git -C "$XBPS_DISTDIR" clean -dfx
}
merge_custom_packages() {
	if [ "$(git -C "$XBPS_DISTDIR" status -s)" ]; then
		error "Local void-packages clone not clean; refusing to merge custom packages!"
	fi

	local branch="$void_packages_branch"
	local origin="origin/$branch"
	case "$(status_of_void_packages $branch $origin)" in
		"diverged")
			local total_commmits=$(git -C "$XBPS_DISTDIR" rev-list --count HEAD) # e.g. 1 on shallow clones
			if [ $total_commmits -gt 1 ]; then
				error "Refusing to merge custom packages onto diverged $branch with more than one commit to $origin!"
			fi
			;;
		"ahead") error "Refusing to merge custom packages to $branch which is ahead of $origin!" ;;
	esac

	log "Merging custom packages and patches into void-packages..."
	custom_packages_setup=true
	local profile_packages=($(echo "${profiles[@]/%/\/packages}"))
	for packages in "${profile_packages[@]}"; do
		# TODO: print from which profile!
		if ! "$base_dir"/packages/merge.sh "$packages" "$XBPS_DISTDIR"; then
			error "Merge of custom packages failed!"
		fi
	done
}
gen_clean_excludes() { for i in $@; do echo "-e $i "; done; }
teardown_custom_packages() {
	$custom_packages_setup || return 0

	log "Cleaning up custom packages and patches from void-packages..."
	git -C "$XBPS_DISTDIR" checkout . &>/dev/null
	git -C "$XBPS_DISTDIR" clean -xfd $(gen_clean_excludes hostdir* masterdir* etc/conf .xbps-checkvers-*.plist) >/dev/null
	custom_packages_setup=false
}
setup_void_packages() {
	if [ ! -e "$XBPS_DISTDIR" ]; then
		local git_extra=()
		local msg_extra=""
		if $void_packages_shallow; then
			git_extra+=("--depth 1")
			msg_extra="shallow "
		fi
		if [ "$void_packages_branch" ]; then
			git_extra+=("-b $void_packages_branch")
		fi

		log "Creating a ${msg_extra}local clone of $void_packages..."
		git clone ${git_extra[@]} $void_packages "$XBPS_DISTDIR"
		update_void_packages_branch
	else
		update_void_packages
	fi
	merge_custom_packages
}
check_pkg_updates() {
	[ "$1" ] && pkgs_build=($@)

	local chdir=false
	[[ "$(basename "$PWD")" = "void-packages"* ]] || chdir=true
	$chdir && pushd "$XBPS_DISTDIR" >/dev/null || :

	log "Checking updates for ${#pkgs_build[@]} packages..."
	local updates="" tmp=""
	for pkg in ${pkgs_build[@]}; do
		tmp="$(./xbps-src update-check $pkg || error "Running update-check failed for '$pkg'!")"
		[ "$tmp" ] && updates+="$tmp\n"
	done
	if [ "$updates" ]; then
		warn "Some packages (listed below) appear to be out of date:"
		echo -e "${updates::-2}"
	fi

	$chdir && popd >/dev/null || :
}
print_build_config() {
	local pkgs_to_build="$(fold_offset 16 "${pkgs_build[@]}")"
	log "Void package build configuration:

  masterdir:    $masterdir
  host target:  $host_target
  cross target: ${cross_target:-<none>}
  build target: $build_target
  packages:     ${pkgs_to_build:-<none>}
  custom:       $custom_packages_setup
  chroot:       $build_chroot_preserve
"
}
build_packages() {
	[ "$1" ] && pkgs_build=($@)

	local chdir=false
	[[ "$(basename "$PWD")" = "void-packages"* ]] || chdir=true
	$chdir && pushd "$XBPS_DISTDIR" >/dev/null || :

	# prep
	print_build_config
	if [ -e $masterdir ]; then
		if [ "$build_chroot_preserve" = "none" ]; then
			log "Removing existing build chroot..."
			$sudo rm -rf $masterdir
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

	setup_xbps_src_conf
	#check_pkg_updates

	# build packages
	for pkg in ${pkgs_build[@]}; do
		if [ "$cross_target" ]; then
			log "Cross-compiling extra package '$pkg' for $cross_target..."
			./xbps-src -m $masterdir -a $cross_target pkg $pkg
		else
			log "Compiling extra package '$pkg' for $host_target..."
			./xbps-src -m $masterdir pkg $pkg
		fi
	done

	$chdir && popd >/dev/null || :
}

xbps_config_prep
