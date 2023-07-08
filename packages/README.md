# Packages
Extra `srcpkg`s to be overlaid on top of [`void-packages`](https://github.com/void-linux/void-packages).

## Usage
Any (sub)directories here containing a `template` file are copied directly to `void-packages/srcpkgs` during runtime automatically if [`extra_build_pkgs`](../config.sh) is configured (and `-B` isn't gived to [`mkrootfs.sh`](../mkrootfs.sh)).

Custom (or modified) shlibs should be placed in a `custom-shlibs` file in the root of this directory.

Custom (or modified) virtual package definitions should be placed in a `custom-virtuals` file in the root of this directory.

Additional patches to be applied on `void-packages` can also be placed in `patches` directory as well in form of `*.patch` or `*.diff` files (need to be `patch -p1` compatible).

Example layout:
```
packages
├── mypkg
│   └── template
├── mypkg-devel -> mypkg
├── patches
│   └── example.patch
├── custom-shlibs
└── custom-virtuals
```

After that call `merge.sh` to:
1. Copy all package directories to void-packages' `srcpkgs`
2. Merge `custom-shlibs` with `common/custom-shlibs`
3. Merge `custom-virtuals` with `etc/defaults.virtual`
4. Apply `patches/*.{patch,diff}`

Based on the idea of [`nvoid`](https://github.com/not-void/nvoid) alternative `xbps-src` repo.

## Patches
* Add support for [checking updates to git packages](patches/0001-update-check-add-support-for-git-packages.patch)

## Checking for package updates
Updates for packages defined in a config can be checked using:
```sh
./mkrootfs.sh --config <config file> --check-updates-only
# or even shorter
./mkrootfs.sh -c <config file> -u
```
Which should output something similar to:
```
$ ./mkrootfs.sh -c config.gnome.sh -u
...
>> Checking updates for 32 packages...
WARN: Some packages (listed below) appear to be out of date:
mutter-f5b1aa6e0be07e48508c32b81b4056626a56174c -> mutter-7da19fd844361571fd1acfdbbbf46cbef28fff29
gnome-shell-ed030b0b31b2a5a71eef28431df2058f1e469d68 -> gnome-shell-0d30d096202a0875895517cfae433c9edcb54d48
pmos-tweaks-0.12.0 -> pmos-tweaks-0.13.0
>> Cleaning up custom packages and patches from void-packages...
```
Once adjustments to the `template`s have been made the packages can be built without involving a full rootfs via:
```sh
./mkrootfs.sh --config <config file> --build-pkgs-only
# or even shorter
./mkrootfs.sh -c <config file> -b
```

## Updating custom packages tracking git hashes
When packages are tracking git hashes of repos their `template` should contain:
```sh
_commit=<commit SHA-1 hash>
```
Example:
```sh
_commit=c7effc8390e49f42a1971587b2bb6e2ecf39e67f
```
Something like `_branch=master` may also be present above in case the tracked branch isn't `main`.

Defined `version` in `template` should be of form:
```
version=<latest repo tag>+git<date of commit/updating in yyyymmdd format>
```
Example:
```
version=1.21.1+git20221216
```
This allows for updates with built packages always cached locally.
