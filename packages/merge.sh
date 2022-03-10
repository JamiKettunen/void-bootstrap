#!/bin/bash
set -e
merge_root="$(readlink -f "$(dirname "$0")")"
void_packages="$1"
void_shlibs="$void_packages/common/shlibs"
void_virtuals="$void_packages/etc/defaults.virtual"
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

	custom_shlibs_lines="$(grep -Ev '^(#|$)' "$custom_shlibs")"
	echo "Merging $(echo "$custom_shlibs_lines" | wc -l) custom shlibs..."
	while IFS="" read shlib; do
		soname="${shlib% *}" # e.g. "libwlroots.so.7"
		pkgfull="${shlib##* }" # e.g. "wlroots-legacy-0.12.0_1"
		pkgname="${pkgfull%-*}" # e.g. "wlroots-legacy"
		if ! grep -Eq "^$soname $pkgname-[0-9+]" "$void_shlibs"; then
			sed "/^$soname\ /d" -i "$void_shlibs"
			echo "$shlib" >> "$void_shlibs"
		fi
	done < <(echo "$custom_shlibs_lines")
}
merge_virtuals() {
	custom_virtuals="$merge_root/custom-virtuals"
	[ -e "$custom_virtuals" ] || return 0

	custom_virtuals_lines="$(grep -Ev '^(#|$)' "$custom_virtuals")"
	echo "Merging $(echo "$custom_virtuals_lines" | wc -l) custom virtuals..."
	while IFS="" read virtual; do
		vpkgname="${virtual% *}" # e.g. "java-environment"
		if grep -Eq "^$vpkgname " "$void_virtuals"; then
			sed "/^$vpkgname\ /d" -i "$void_virtuals"
		fi
		echo "$virtual" >> "$void_virtuals"
	done < <(echo "$custom_virtuals_lines")
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
merge_virtuals
merge_patches
