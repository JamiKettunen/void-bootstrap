mountpoint -q /sys/kernel/tracing || mount -n -t tracefs tracefs /sys/kernel/tracing
