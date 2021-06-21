# VoidBootstrap
Customize & create Void Linux rootfs images.

## Supported architectures
* `aarch64`
* `armv6l`
* `armv7l`
* `x86_64`
* `i686`

## Building
Create a `config.custom.sh`, tweak options defined in [`config.sh`](config.sh) as you please & simply run the [`mkrootfs.sh`](mkrootfs.sh) script:
```
$ ./mkrootfs.sh
```
After this `./deploy.sh` can be ran to deploy the rootfs to an Android device.

## Usage
### mkrootfs.sh
Optional arguments
* `-c alternate_config.sh`: Choose extra config file other than the `config.custom.sh` default
* `-B`: Don't build extra packages if specified
* `-N`: Don't color output if specified
### deploy.sh
Optional arguments
* `-i rootfs.img`: Specify a rootfs image path to deploy
* `-s rootfs_resize_gb`: Gigabytes to resize the deployed image to, defaults to `8`
* `-t target_location`: Rootfs target location on the device
  * Defaults to `/data/void-rootfs.img`
  * Should point to a partition by name such as `system` when flashing via `fastboot`
  * When set to `nbd` exports `rootfs` via a network block device server which can be booted via [an initramfs](https://github.com/JamiKettunen/initramfs-tools)
* `-f`: Automatically answer yes to any "overwrite existing rootfs" questions
* `-k`: Automatically answer yes to any "kill running NBD server" questions
* `-R`: Don't reboot the device after rootfs deployment

## Optional scripts
The following scripts can be created to be sourced by `mkrootfs.sh` if they exist:
* `mkrootfs.pre.sh`: Executed before any of the other functions; can be used for custom function overrides and such
* `mkrootfs.custom.sh`: Executed inside the rootfs before cleanup operations; can be used to script more complex environments if `config.sh` doesn't cut it
* `mkrootfs.post.sh`: Executed after rootfs image creation (and compression); can be used for local CI build artifact uploads or such actions
