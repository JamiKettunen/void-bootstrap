#!/bin/bash
xbps_config_prep() {
	masterdir="masterdir$musl_suffix"
	host_target="${host_arch}${musl_suffix}"
	[ "$host_arch" != "$arch" ] && cross_target="${arch}${musl_suffix}"
	XBPS_DISTFILES_MIRROR="$mirror"
	[ "$XBPS_DISTDIR" ] || XBPS_DISTDIR="void-packages"
	[ "$build_chroot_preserve" ] || build_chroot_preserve="none"
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
setup_void_packages() {
	if [ ! -e "$XBPS_DISTDIR" ]; then
		log "Creating a local clone of $void_packages..."
		git clone $void_packages "$XBPS_DISTDIR"
	else
		log "Pulling updates to local void-packages clone..."
		git -C "$XBPS_DISTDIR" pull \
			|| warn "Couldn't pull updates to void-packages clone automatically; ignoring..."
	fi
}
check_pkg_updates() {
	log "Checking updates for packages which will be built..."
	local updates=""
	for pkg in ${extra_build_pkgs[@]}; do
		updates+="$(./xbps-src update-check $pkg)"
	done
	if [ "$updates" ]; then
		warn "Some packages (listed below) appear to be out of date; continuing anyway..."
		echo -e "$updates"
	fi
}
print_build_config() {
	log "Void package build configuration:

  masterdir:    $masterdir
  host target:  $host_target
  cross target: $cross_target
  packages:     $(fold_offset 16 "${extra_build_pkgs[@]}")
  chroot:       $build_chroot_preserve
"
}
build_packages() {
	pushd "$XBPS_DISTDIR" >/dev/null

	# prep
	print_build_config
	if [ -e $masterdir ]; then
		if [ "$build_chroot_preserve" = "none" ]; then
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

	setup_xbps_src_conf
	#check_pkg_updates

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

xbps_config_prep
