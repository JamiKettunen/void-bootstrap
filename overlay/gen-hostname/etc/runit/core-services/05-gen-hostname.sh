DT_COMPATIBLE_NODE=/sys/firmware/devicetree/base/compatible
[ -r $DT_COMPATIBLE_NODE ] || return

DT_MODEL="$(cat -v $DT_COMPATIBLE_NODE | cut -d'^' -f1 | tr ',' '-')" # e.g. "oneplus-dumpling"
[ -r /etc/hostname ] && read -r HOSTNAME < /etc/hostname
[ "$HOSTNAME" = "$DT_MODEL" ] && return

echo "$DT_MODEL" > /etc/hostname
