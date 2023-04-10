#!/bin/bash

# check CPU architecture
if [ -z "$ARCH" ]; then
	case $(uname -m) in
		x86_64)
			ARCH='amd64'
			;;
		aarch64)
			ARCH='arm64'
			;;
		*)
			echo 'Unsupported CPU architecture'
			exit 1
			;;
	esac
fi


# docker is separate to allow for independent install
$(dirname $0)/install-docker.sh || exit $?


gpg_setup() {
	# username and email
	local username
	[ -n "$USERNAME" ] && username=$USERNAME
	while [ -z "$username" ]; do
		read -rp "Enter a username (e.g. John Doe): " username
		echo
	done

	local email
	[ -n "$EMAIL" ] && email=$EMAIL
	while [ -z "$email" ]; do
		read -rp "Enter an email (e.g. jdoe@example.com): " email
		echo
	done

	# GPG_TTY needs to be set or the passphrase prompt will not appear in terminal
	if [ ! -f $HOME/.bashrc ] || ! grep -q GPG_TTY $HOME/.bashrc; then
		echo 'export GPG_TTY=$(tty)' >> $HOME/.bashrc
		export GPG_TTY=$(tty)
	fi

	# verify a gpg key has been initialized
	local key='gpg --list-key "$username" 2> /dev/null | awk "/^pub/{getline;print}" | xargs'
	if ! gpg --list-key "$username" &> /dev/null; then
		local passphrase
		[ -n "$PASSPHRASE" ] && passphrase=$PASSPHRASE
		while [ -z "$passphrase" ]; do
			read -rsp "Enter a passphrase: " passphrase
			echo
			read -rsp "Re-enter passphrase: "
			echo
			[ "$passphrase" != "$REPLY" ] && unset passphrase
		done
		gpg --batch --passphrase "$passphrase" --quick-gen-key \
			"$username <$email>" rsa4096 default 0 && key=$(eval $key)
		if [ -z "$key" ]; then
			echo "ERROR: gpg key is empty, check setup and try again."
			exit 1
		fi
		echo "$passphrase" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --quick-add-key $key rsa4096 default 0
	else
		key=$(eval $key)
	fi

	# initialize pass using gpg key
	pass &> /dev/null && pass init $key > /dev/null || exit 1
}


# install dependencies required for docker-to-ghcr
# (assuming a Debian based distro)
if ! which jq > /dev/null; then
	echo 'Installing jq...'
	sudo apt-get update && sudo apt-get install -y jq || exit 1
fi

if ! which gpg > /dev/null; then
	echo 'Installing gpg...'
	sudo apt-get update && sudo apt-get install -y gnupg || exit 1
fi

if ! which pass > /dev/null; then
	echo 'Installing pass...'
	sudo apt-get update && sudo apt-get install -y pass || exit 1
fi

if ! which docker-credential-pass > /dev/null; then
	echo "Installing docker-credential-pass..."
	repo='docker/docker-credential-helpers'
	ver=$(curl -sL https://api.github.com/repos/${repo}/releases/latest | jq -r '.tag_name')
	curl -sS \
		https://github.com/${repo}/releases/download/${ver}/docker-credential-pass-${ver}.linux-$ARCH \
		-o /usr/local/bin/docker-credential-pass || exit $?
	sudo chmod +x /usr/local/bin/docker-credential-pass || exit $?
	jq -n '{"credsStore": "pass"}' > $HOME/.docker/config.json || exit $?
fi

gpg_setup
