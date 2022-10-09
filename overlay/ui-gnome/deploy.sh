#!/bin/bash
set -e
xbps-install -y dbus-elogind-libs dbus-elogind-x11 xdg-user-dirs-gtk # Desktop backend stuff
xbps-install -y mesa-dri glxinfo mesa-demos                          # GPU
xbps-install -y xorg-server-xwayland xf86-video-fbdev                # Base GUI

# A small GNOME desktop with some default applications installed
xbps-install -y gnome-core \
	gnome-tweaks gnome-console gnome-system-monitor gnome-screenshot \
	gnome-disk-utility gnome-clocks gnome-calendar \
	gedit

enable_sv gdm
