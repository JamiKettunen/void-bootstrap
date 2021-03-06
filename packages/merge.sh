#!/bin/bash
merge_root="$(readlink -f "$(dirname "$0")")"
void_packages="$1"
void_shlibs="$void_packages/common/shlibs"
void_srcpkgs="$void_packages/srcpkgs"

if [[ ! -f "$void_shlibs" || ! -d "$void_srcpkgs" ]]; then
	echo "ERROR: '$1' (first arg) doesn't look like a void-packages clone!"
	exit 1
fi

merge_pkgs() {
	custom_pkgs_count=$(find -L "$merge_root"/* -type f -name 'template' | wc -l)
	[ $custom_pkgs_count -gt 0 ] || return 0

	echo "Merging $custom_pkgs_count custom packages..."
	while IFS="" read pkgpath; do
		[ -e "$pkgpath/template" ] || continue # ignore invalid pkg dirs

		pkgname="$(basename "$pkgpath")" # e.g. "wlroots-legacy"
		[ -e "$void_srcpkgs/$pkgname" ] && rm -r "$void_srcpkgs/$pkgname"
		cp -a "$pkgpath" "$void_srcpkgs"
	done <<< "$(find "$merge_root"/* -not -type f)"
}
merge_shlibs() {
	custom_shlibs="$merge_root/custom-shlibs"
	[ -e "$custom_shlibs" ] || return 0

	echo "Merging $(wc -l < "$custom_shlibs") custom shlibs..."
	while IFS="" read shlib; do
		soname="${shlib% *}" # e.g. "libwlroots.so.7"
		pkgfull="${shlib##* }" # e.g. "wlroots-legacy-0.12.0_1"
		pkgname="${pkgfull%-*}" # e.g. "wlroots-legacy"
		if ! grep -Eq "^$soname $pkgname-[0-9+]" "$void_shlibs"; then
			sed "/^$soname\ /d" -i "$void_shlibs"
			echo "$shlib" >> "$void_shlibs"
		fi
	done <<< "$(<"$custom_shlibs")"
}
merge_patches() {
	[ -e "$merge_root"/patches ] || return 0
	patches_count=$(find "$merge_root"/patches/* -type f | wc -l)
	[ $patches_count -gt 0 ] || return 0

	echo "Applying $patches_count custom patches..."
	pushd "$void_packages" > /dev/null
	while IFS="" read filepath; do
		if ! patch -p1 --forward < "$filepath"; then
			echo "ERROR: Failed to apply $(basename "$filepath")!"
			exit 1
		fi
	done <<< "$(find "$merge_root"/patches/* -type f)"
	popd > /dev/null
}

merge_pkgs
merge_shlibs
merge_patches
