# Overlays
Contents from directories added here can be copied over to the rootfs when they are enabled via [config.sh](../config.sh) `overlays` array.

## Scripting
If additional commands need to be run to finish deploying the overlay a `deploy.sh` shell script can be created to be ran as `root` on the rootfs. `deploy_host.sh` on the other hand will be sourced by `mkrootfs.sh` when e.g. files from the host machine should be copied to the rootfs.

## Packages
TODO: Additional binary packages can also be installed from overlays if `packages/*.xbps` files are found.
