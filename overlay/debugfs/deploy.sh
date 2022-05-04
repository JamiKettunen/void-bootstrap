#!/bin/bash
ln -s /sys/kernel/debug /d
echo 'debugfs		/sys/kernel/debug	debugfs	defaults                0       0' >> /etc/fstab
