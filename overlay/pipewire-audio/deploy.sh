#!/bin/bash
xbps-install -y pipewire alsa-pipewire rtkit pulseaudio-utils alsa-utils

# Setup BT bits conditionally
if command -v bluetoothctl >/dev/null; then
	xbps-install -y libspa-bluetooth
fi

# Setup ALSA bits
mkdir -p /etc/alsa/conf.d
ln -s /usr/share/alsa/alsa.conf.d/{50-pipewire,99-pipewire-default}.conf /etc/alsa/conf.d/
