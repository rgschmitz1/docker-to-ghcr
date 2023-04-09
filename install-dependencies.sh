#!/bin/bash

# username and email
[ -z "$USERNAME" ] && USERNAME='John Doe'
[ -z "$EMAIL" ] && EMAIL='jdoe@example.com'

# check CPU architecture
if [ -z "$ARCH" ]; then
	case $(uname -m) in
		x86_64)
			export ARCH='amd64'
			;;
		aarch64)
			export ARCH='arm64'
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
	# GPG_TTY needs to be set or the passphrase prompt will not appear in terminal
	if ! grep -q GPG_TTY ~/.bashrc; then
		echo 'export GPG_TTY=$(tty)' >> ~/.bashrc
		export GPG_TTY=$(tty)
	fi

	# verify a gpg key has been initialized
	local key='gpg --list-key "$USERNAME" 2> /dev/null | awk "/^pub/{getline;print}" | xargs'
	if ! gpg --list-key "$USERNAME" &> /dev/null; then
		[ -z "$PASSPHRASE" ] && local passphrase || local passphrase=$PASSPHRASE
		while [ -z "$passphrase" ]; do
			read -rsp "Enter a passphrase: " passphrase
			echo
			read -rsp "Re-enter passphrase: "
			echo
			[ "$passphrase" != "$REPLY" ] && unset passphrase
		done
		gpg --batch --passphrase "$passphrase" --quick-gen-key \
			"$USERNAME <$EMAIL>" rsa4096 default 0 && key=$(eval $key)
		if [ -z "$key" ]; then
			echo "ERROR: gpg key is empty, check setup and try again."
			exit 1
		fi
		echo "$passphrase" | gpg --batch --pinentry-mode loopback --passphrase-fd 0 --quick-add-key $key rsa4096 default 0
	else
		key=$(eval $key)
	fi
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

gpg_setup

if ! which pass > /dev/null; then
	echo 'Installing pass...'
	sudo apt-get update && sudo apt-get install -y pass || exit 1

	# initialize pass using gpg key
	pass init $key
fi

if ! which docker-credential-pass > /dev/null; then
	echo "Installing docker-credential-pass..."
	sudo curl -sSL https://github.com/docker/docker-credential-helpers/releases/download/v0.7.0/docker-credential-pass-v0.7.0.linux-$ARCH \
		-o /usr/local/bin/docker-credential-pass || exit $?
	sudo chmod +x /usr/local/bin/docker-credential-pass || exit $?
	jq -n '{"credsStore": "pass"}' > ~/.docker/config.json || exit $?
fi
