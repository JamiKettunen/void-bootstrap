#!/usr/bin/env sh
set -e
: ${RNDIS_USB_NET:=172.16.42.0/24}
: ${RNDIS_USB_HOST:=172.16.42.2}
: ${RNDIS_USB_DEVICE:=172.16.42.1}

# TODO: use nftables instead?
sudo sysctl net.ipv4.ip_forward=1 >/dev/null
sudo iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A FORWARD -s $RNDIS_USB_NET -j ACCEPT
sudo iptables -A POSTROUTING -t nat -j MASQUERADE -s $RNDIS_USB_NET

MANUAL_STEPS_NEEDED=1
if ip a | grep -q "inet $RNDIS_USB_HOST"; then
	ssh root@$RNDIS_USB_DEVICE sv start rndis-tethering && MANUAL_STEPS_NEEDED=0
fi

if [ $MANUAL_STEPS_NEEDED -eq 1 ]; then
	cat <<'EOF'
>> Now run 'ip route add default via $RNDIS_USB_HOST dev usb0' on your device!
   (running 'ip route del default via $RNDIS_USB_HOST' will undo this)

>> With 'usbd' package 'sv start rndis-tethering' & 'sv stop rndis-tethering'
   will work as well.
EOF
fi
