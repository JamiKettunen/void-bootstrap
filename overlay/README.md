# Overlays
Contents from directories added here can be copied over to the rootfs when they are enabled via [config.sh](../config.sh) `overlays` array.

A `home/ALL` directory can be made if files should be copied to home directories of all users (except `root`).

An empty directories can be tracked by git if it contains a file (even an empty one), `.keep` is the supported filename and these will be removed at the end of rootfs creation.

## Scripting
If additional commands need to be run to finish deploying the overlay a `deploy.sh` shell script can be created to be ran as `root` on the rootfs (functions and variables from [`setup.sh`](setup.sh.in) is sourced too automatically!).

`deploy_host.sh` on the other hand will be sourced by `mkrootfs.sh` when e.g. files from the host machine should be copied to the rootfs.
