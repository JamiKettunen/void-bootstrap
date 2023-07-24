#!/bin/bash
# Copy the public SSH key(s) of your host to the rootfs for seamless authentication.
host_ssh_pubkey() {
	local pubkeys=(
		$HOME/.ssh/id_rsa.pub
	)

	for user in ${usernames[*]}; do
		local user_home="home/$user"
		[ "$user" = "root" ] && user_home="root"
		local ssh_dir="$rootfs_dir"/$user_home/.ssh
		[ -e "$ssh_dir" ] || $sudo mkdir -p "$ssh_dir"
		cat "${pubkeys[@]}" | $sudo tee -a "$ssh_dir"/authorized_keys >/dev/null
	done
}
host_ssh_pubkey
