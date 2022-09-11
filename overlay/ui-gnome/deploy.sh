#!/bin/bash
set -e

# HACK: Fixes GDM not starting as of 2021-06-17
# due to an incorrect rpath in cross-compiled gnome-shell-40.2_1
ln -s / /usr/aarch64-linux-musl
ln -s / /usr/aarch64-linux-gnu

xbps-install -y dbus-elogind-libs dbus-elogind-x11 xdg-user-dirs-gtk # Desktop backend stuff
xbps-install -y mesa-dri glxinfo mesa-demos                          # GPU
xbps-install -y xorg-server-xwayland xf86-video-fbdev                # Base GUI

# A small GNOME desktop with some default applications installed
xbps-install -y gnome-core \
	gnome-tweaks gnome-terminal gnome-system-monitor gnome-screenshot \
	gnome-disk-utility gnome-clocks gnome-calendar \
	gedit

enable_sv gdm
