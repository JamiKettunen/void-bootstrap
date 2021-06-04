#!/bin/sh
set -e
# TODO: Check if already done!
sudo sysctl net.ipv4.ip_forward=1
sudo iptables -P FORWARD ACCEPT
sudo iptables -A POSTROUTING -t nat -j MASQUERADE -s 172.16.42.0/24
echo ">> Now run 'ip route add default via 172.16.42.2 dev usb0' on your device!"
echo "   (running 'ip route del default via 172.16.42.2' will undo this)"
