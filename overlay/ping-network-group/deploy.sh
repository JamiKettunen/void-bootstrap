#!/bin/bash
network_gid=$(getent group network | cut -d':' -f3) # e.g. 21
echo "net.ipv4.ping_group_range = $network_gid $network_gid" >> /etc/sysctl.conf
