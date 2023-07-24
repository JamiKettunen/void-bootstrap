#!/bin/bash
set -e
enable_sv ModemManager
dbus_sv="/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service"
rm $dbus_sv
echo "noextract=$dbus_sv" > /etc/xbps.d/modemmanager-runit.conf
