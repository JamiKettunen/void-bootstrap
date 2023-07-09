# VoidBootstrap
Customize & create Void Linux rootfs images.

## Supported architectures
`aarch64`, `armv6l`, `armv7l`, `x86_64` and `i686`

## Building
Create a `config.custom.sh`, in it tweak options defined in [`config.sh`](config.sh) as you please & simply run the [`mkrootfs.sh`](mkrootfs.sh) script:
```
$ ./mkrootfs.sh
```
After this `./deploy.sh` can be ran to deploy the rootfs to an Android device.

A `config.local.sh` is also sourced in case it exists to utilize e.g. a local-only `distcc` setup.

## Usage
### mkrootfs.sh
Builds the OS image.

Optional arguments:
* `-a arch`: Choose an architecture other than the one defined in `config*.sh`; see [supported architectures](#supported-architectures) above for choices
* `-B`: Don't build extra packages if specified
* `-b`: Only build extra packages instead of creating a rootfs
* `-c alternate_config.sh`: Choose extra config file other than the `config.custom.sh` default
* `-f`: Force rebuild of extra packages even if an up-to-date `.xbps` package is found
* `-m true|false`: Choose whether to enable musl libc instead of glibc or not
* `-N`: Don't color output if specified
* `-u`: Only check updates to extra packages instead of creating a rootfs
* `-t`: Only teardown any custom changes made to the cloned void-packages repo
### deploy.sh
Flashes the built image to a device.

Optional arguments:
* `-i rootfs.img`: Specify a rootfs image path to deploy
* `-s rootfs_resize_gb`: Gigabytes to resize the deployed image to, defaults to `8`
* `-t target_location`: Rootfs target location on the device
  * Defaults to `/data/void-rootfs.img`
  * Should point to a partition by name such as `system` when flashing via `fastboot` (but is also accepted in recovery mode)
  * When set to `nbd` exports `rootfs` via a network block device server which can be booted via [an initramfs](https://github.com/JamiKettunen/initramfs-tools)
* `-b sparse_blocksize`: Use this block size when converting rootfs to sparse image for `fastboot` flashing, defaults to `4096`
* `-f`: Automatically answer yes to any "overwrite existing rootfs" questions
* `-k`: Automatically answer yes to any "kill running NBD server" questions
* `-R`: Don't reboot the device after rootfs deployment

## Optional scripts
The following scripts can be created to be sourced by `mkrootfs.sh` if they exist:
* `mkrootfs.pre.sh`: Executed before any of the other functions; can be used for custom function overrides and such
* `mkrootfs.custom.sh`: Executed inside the rootfs before cleanup operations; can be used to script more complex environments if `config.sh` doesn't cut it
* `mkrootfs.post.sh`: Executed after rootfs image creation (and compression); can be used for local CI build artifact uploads or such actions

## Custom tweaks to void-packages
See [packages/README.md](packages/README.md) for more details.

## External repos
Standalone external repositories can use `void-bootstrap` as a base to avoid forking or extra maintenance burden of the core script with a setup similar to the following:
```bash
cat <<'EOF' > mkrootfs.sh
#!/usr/bin/env bash
set -e
cd "$(readlink -f "$(dirname "$0")")"
if [ -d void-bootstrap ]; then
	if [[ "$(git -C void-bootstrap remote -v 2>/dev/null)" && "$(find void-bootstrap/.git -maxdepth 0 -mmin +240)" ]]; then
		git -C void-bootstrap pull --ff-only
	fi
else
	git clone https://github.com/JamiKettunen/void-bootstrap
fi
void-bootstrap/"${0##*/}" -p "$PWD" "$@"
EOF
ln -s mkrootfs.sh deploy.sh
ln -s mkrootfs.sh tethering.sh
```
Afterwards feel free to [setup a `packages` structure](https://github.com/JamiKettunen/void-bootstrap/tree/master/packages#readme) or [add extra `overlays`](https://github.com/JamiKettunen/void-bootstrap/tree/master/overlay#readme) to this new repo.

By the end your external repo layout could look like:
```
external-void-bootstrap
├── overlay
│   └── example
│       └── deploy.sh
├── packages
│   ├── mypkg
│   │   └── template
│   ├── mypkg-devel -> mypkg
│   ├── patches
│   │   └── example.patch
│   └── custom-shlibs
├── config.custom.sh
├── deploy.sh -> mkrootfs.sh
├── mkrootfs.sh
└── tethering.sh -> mkrootfs.sh
```

## DST Root CA X3 certificate verification failed
This can happen while starting to build extra packages in case your host system has broken certificates (e.g. Arch).

It can be fixed by importing the `ISRG Root X1` cert and deleting the expired `DST Root CA X3` one like so:
```bash
curl -LO https://letsencrypt.org/certs/isrgrootx1.pem
sudo trust anchor --store isrgrootx1.pem
sudo rm isrgrootx1.pem /etc/ssl/certs/2e5ac55d.0
```

## License
All code in this repository is licensed under a [`BSD-2-Clause`](LICENSE) license.
