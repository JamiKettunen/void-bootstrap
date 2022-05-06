# Config file for Void Bootstrap's mkrootfs.py

# Void Linux release tarballs to target
# e.g. "current" or "20210316"
# https://alpha.de.repo.voidlinux.org/live
release="20210930"

# Backend to use for executing scripts and commands on the rootfs; supported choices include:
# "chroot"
# "systemd-nspawn"
# "" = "systemd-nspawn" if found, else "chroot"
backend=""

# Target rootfs architecture; currently available choices include:
# "aarch64"
# "armv6l"
# "armv7l"
# "x86_64"
# "i686"
# NOTE: i686 doesn't have a musl rootfs variant available!
arch="aarch64"

# Use musl as the standard C library instead of glibc? (true|false)
musl=true

# DNS nameservers to configure under rootfs /etc/resolv.conf
# e.g. (1.1.1.1)
# NOTE: () = copy from host
dns=()

# Configure user account(s) on the Void install
# FORMAT:
# 1. login name
# 2. optional password (plain text or encrypted)
# 3. numerical user/group ID
# 4. extra groups (comma separated)
# 5. shell path
# 6. full name / comment
# NOTES:
# 1. "$USER" = match host username
# 2. If no password is defined it defaults to users_pw_default
# 3. root will always be on this list automatically & uses users_pw_default
# 4. Plain text password CANNOT contain ':' or '|' -> use mkpasswd instead
# See "man mkpasswd" and "man chpasswd"
# https://docs.voidlinux.org/config/users-and-groups.html#default-groups
users=()

# Default password to set for users in case one isn't defined above
# NOTE: "" = disable login
users_pw_default="voidlinux"

# Use the following method to encrypt plain text passwords for users & users_pw_default:
# "DES"
# "MD5"
# "SHA256"
# "SHA512"
# WARNING: DO NOT set if ANY of the password are in encrypted form already!
users_pw_encryption="SHA256"

# Common groups to add all new users in
users_groups_common=()

# Default shell to set for all users
users_shell_default="/bin/bash"

# Should invocations of sudo prompt for passwords? (true|false)
# WARNING: Disabling this causes anything requiring superuser privileges to execute right away!
users_sudo_askpass=true

# System hostname to configure
hostname="voidlinux"

# Void Linux mirror to use for all downloads
# https://docs.voidlinux.org/xbps/repositories/mirrors/index.html
# NOTE: "" = DEF_MIRROR as defined in mkrootfs.sh
mirror=""

# Rootfs filename format:
# "%a" -> architecture (e.g. "aarch64" or "aarch64-musl")
# https://man.voidlinux.org/date
img_name_format="%a-rootfs-$(date +'%Y-%m-%d').img"

# Maximum size the rootfs image is expected to reach during the creation process.
# "0" = don't move build result to an image file
img_size="4G"

# Rootfs image final compression:
# none -> keep as raw rootfs.img
# xz   -> create xz compressed rootfs.img.xz
# gz   -> create gz compressed rootfs.img.gz
img_compress="none"

# Main working directory of script; can be e.g. "/tmp/void-bootstrap" if you have memory to spare
# NOTE: "" = match mkrootfs.sh directory
work_dir="/tmp/void-bootstrap"

# XBPS package cache directory to use; e.g. "pkgcache"
# NOTE: "" = disable build package cache
pkgcache_dir="pkgcache"

# Allow logging in as root via SSH? (true|false)
# NOTE: This is generally a bad idea
permit_root_login=false

# Packages to ignore on the rootfs
# These will always be satisfied dependencies
ignorepkg=()

# Files to avoid extracting from all packages
# These are automatically added to rm_files
# NOTE: All patterns with globs (*) have to be quoted!
noextract=()

# File patterns to remove from the rootfs
# Automatically contains everything from noextract
# NOTE: All patterns with globs (*) have to be quoted!
rm_files=()

# Packages to remove from rootfs
# These should be a part of ignorepkg to avoid breaking soft-dependencies of e.g. void-base
rm_pkgs=()

# Additional packages to install
base_pkgs=()

# Void packages git repo to clone when packages are defined in extra_build_pkgs
void_packages="https://github.com/void-linux/void-packages.git"

# Repo branch to clone; e.g. "master"
# "" = repo default
void_packages_branch=""

# Should the repo be cloned/updated with --depth 1? (true|false)
void_packages_shallow=true

# Void package build chroot preservation options:
# "none"   -> don't preserve compilation masterdir environments
# "ccache" -> preserve only ccache from previous runs (recommended)
# "all"    -> keep compilation environments as-is from previous runs
build_chroot_preserve="ccache"

# Extra packages to build/install from local void-packages clone
# NOTE: Use extra_install_pkgs=(${extra_build_pkgs[@]}) to install all built packages
extra_build_pkgs=()
extra_install_pkgs=()

# Additional runit services to enable
enable_sv=()

# Default runit services to disable
disable_sv=()

# Overlay directories to deploy on the rootfs
# See overlay/README.md
overlays=()

# xbps-src options
# https://github.com/void-linux/void-packages/blob/master/etc/defaults.conf
#XBPS_DISTDIR="/path/to/void-packages"
XBPS_ALLOW_RESTRICTED="yes"
XBPS_CCACHE="yes"
#XBPS_CHECK_PKGS="full"
#XBPS_DEBUG_PKGS="yes"
XBPS_MAKEJOBS="$(nproc)" # e.g. "16" / "$(nproc)"
XBPS_PRESERVE_PKGS=yes
# TODO: distcc config
