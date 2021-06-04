# MSM8998
ignorepkg=(
	# Unneeded FW
	ipw2100-firmware
	ipw2200-firmware
	zd1211-firmware
	wifi-firmware

	# We likely don't have an ethernet port
	ethtool

	# We most likely won't be using ACPI to boot
	acpid

	# We likely don't have PCI on embedded devices (phones)
	pciutils

	# Only ext4 formatted images supported (currently)
	btrfs-progs
	xfsprogs

	# We'll replace this crappy editor in extra_pkgs
	nvi

	# TODO: We don't need raid -> avoid extra runit stage
	#dmraid
)
noextract=(
	# No rootfs encryption setup -> avoid extra runit stage
	/etc/crypttab

	# For ModemManager debugging without being automatically started by dbus
	/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service
)
rm_pkgs=(
	nvi pciutils btrfs-progs xfsprogs
	#dmraid
)

base_pkgs=(
	# Time & date
	fake-hwclock chrony

	# Bluetooth
	bluez elogind dbus-elogind dnsmasq

	# Tools
	git htop neovim neofetch psmisc rsync xxd curl busybox
	#xtools
	#mlocate

	# Networking
	NetworkManager

	# WLAN
	crda

	# Logging
	socklog-void

	# Misc
	#void-repo-nonfree
)
void_packages="https://github.com/JamiKettunen/void-packages.git"
extra_build_pkgs=(
	# Cellular
	libmbim libqrtr-glib libqmi ModemManager

	# Modem/WLAN
	pd-mapper rmtfs tqftpserv diag-router

	# GPS
	gpsd

	# GPU
	#mesa

	# Misc
	reboot-mode soctemp

	# Initramfs
	#initfs-tools
)
extra_install_pkgs=(
	# Cellular
	libqmi ModemManager

	# Modem/WLAN
	qrtr-ns pd-mapper rmtfs tqftpserv diag-router

	# GPS
	gpsd

	# Misc
	reboot-mode soctemp
)
enable_sv=(
	# Base
	fake-hwclock chronyd sshd dbus bluetoothd
	#elogind

	# Modem/WLAN
	pd-mapper rmtfs tqftpserv diag-router

	# GPS
	gpsd

	# Networking
	NetworkManager

	# Logging
	socklog-unix nanoklogd
)
disable_sv=(
	# Embedded devices don't need more than 1 tty
	agetty-tty{2..6}
)

# Speed
img_compress="gz" # none
build_chroot_preserve="all"

# Misc
permit_root_login=true

# OnePlus 5/5T
hostname="oneplus-5t"
img_name_extra="-op5"
#base_pkgs+=()
extra_build_pkgs+=(
	oneplus-msm8998-firmware
	#oneplus-msm8998-kernel
)
extra_install_pkgs+=(
	oneplus-msm8998-firmware
	#oneplus-msm8998-kernel
)
overlays=(
	# Kernel (hack!)
	#abootimg

	# Allow running "dmesg" without root
	dmesg-noroot

	# Mount debugfs at /d
	debugfs

	# Use "pds://any" as GPSD device
	gpsd-pds

	# SSH public key from host
	#ssh-pubkey

	#host-timezone

	bash
) # custom oneplus5 xfce4 somainline nonfree-repo
