# Packages
Extra `srcpkg`s to be overlaid on top of [`void-packages`](https://github.com/void-linux/void-packages).

## Usage
Any (sub)directories here containing a `template` file are copied directly to `void-packages/srcpkgs` during runtime automatically if [`extra_build_pkgs`](../config.sh) is configured (and `-B` isn't gived to [`mkrootfs.sh`](../mkrootfs.sh)).

Custom (or modified) shlibs should be placed in a `custom-shlibs` file in the root of this directory.

Additional patches to be applied on `void-packages` can also be placed in `patches` directory as well in form of `*.patch` or `*.diff` files (need to be `patch -p1` compatible).

Example layout:
```
packages
├── mypkg
│   └── template
├── mypkg-devel -> mypkg
├── patches
│   └── example.patch
└── custom-shlibs
```

After that call `merge.sh` to merge `custom-shlibs` with void-packages' `common/custom-shlibs` and copy all package directories to `srcpkgs`.

Based on the idea of [`nvoid`](https://github.com/not-void/nvoid) alternative `xbps-src` repo.
