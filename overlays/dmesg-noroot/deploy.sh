#!/bin/bash
mkdir -p /etc/sysctl.d
echo 'kernel.dmesg_restrict = 0' >> /etc/sysctl.d/dmesg-noroot.conf
