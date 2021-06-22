#!/bin/bash
xbps_config_prep() {
	masterdir="masterdir$musl_suffix"
	host_target="${host_arch}${musl_suffix}"
	[ "$host_arch" != "$arch" ] && cross_target="${arch}${musl_suffix}"
	[ "$build_chroot_preserve" ] || build_chroot_preserve="none"
	pkgs_build=(${extra_build_pkgs[@]})
	if [ "$void_packages_privkeyfile" ]; then
		void_packages_privkeyfile="$(readlink -f "$void_packages_privkeyfile")"
		if [ -r "$void_packages_privkeyfile" ]; then
			export GIT_SSH_COMMAND="ssh -i $void_packages_privkeyfile -o StrictHostKeyChecking=no"
		else
			warn "Private key file '$(basename "$void_packages_privkeyfile")' for void-packages not found; ignoring..."
			void_packages_privkeyfile=""
		fi
	fi
	XBPS_DISTFILES_MIRROR="$mirror"
	[ "$XBPS_DISTDIR" ] || XBPS_DISTDIR="void-packages"
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
setup_xbps_src_conf() {
	local xbps_src_config="# as configured in Void Bootstrap's config.sh"
	add_if_set() { for cfg in $@; do cfg="XBPS_$cfg"; [ "${!cfg}" ] && xbps_src_config+="\n$cfg=\"${!cfg}\"" || :; done; }
	add_if_set ALLOW_RESTRICTED CCACHE CHECK_PKGS DEBUG_PKGS DISTFILES_MIRROR MAKEJOBS
	local write_config=true
	if [ -e etc/conf ]; then
		local file_sum="$(sha256sum etc/conf | awk '{print $1}')"
		local new_sum="$(echo -e "$xbps_src_config" | sha256sum | awk '{print $1}')"
		[ "$file_sum" = "$new_sum" ] && write_config=false
	fi
	$write_config && echo -e "$xbps_src_config" > etc/conf || :
}
# Returns void-packages clone branch name; e.g. "master"
branch_of_void_packages() { git -C "$XBPS_DISTDIR" symbolic-ref --short HEAD; }
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
	local branch="$(branch_of_void_packages)"
	if ! $void_packages_shallow; then
		log "Pulling updates to local void-packages clone..."
		git -C "$XBPS_DISTDIR" pull && return

		warn "Couldn't pull updates to void-packages clone; trying shallow method..."
	else
		log "Pulling updates to local void-packages shallow clone..."
		git -C "$XBPS_DISTDIR" fetch --depth 1 # origin $branch:$branch
	fi

	if [[ "$(git -C "$XBPS_DISTDIR" status -s)" ]]; then
		warn "Local void-packages clone not clean; refusing to automatically update!"
		return
	fi

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
	else
		update_void_packages
	fi

	if [ "$rootfs_dir" ]; then
		$sudo sed "s/@VOID_PACKAGES_BRANCH@/$(branch_of_void_packages)/" -i "$rootfs_dir"/setup.sh
	fi
}
check_pkg_updates() {
	[ "$1" ] && pkgs_build=($@)

	local chdir=false
	[[ "$(basename "$PWD")" = "void-packages"* ]] || chdir=true
	$chdir && pushd "$XBPS_DISTDIR" >/dev/null || :

	log "Checking updates for ${#pkgs_build[@]} packages..."
	local updates="" tmp=""
	for pkg in ${pkgs_build[@]}; do
		tmp="$(./xbps-src update-check $pkg)"
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
  packages:     ${pkgs_to_build:-<none>}
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
	# TODO: Make sure somehow that we don't keep building packages that are already up-to-date?
	# - Do this by checking matching version against /packages/**/*.xbps?
	# - Perhaps store a checksum of srcpkgs/$pkg and check against later?
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
