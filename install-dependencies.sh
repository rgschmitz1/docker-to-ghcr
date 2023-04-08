#!/bin/bash

# username and email
[ -z "$USERNAME" ] && USERNAME='Bob Schmitz III'
[ -z "$EMAIL" ] && EMAIL='14095796+rgschmitz1@users.noreply.github.com'


gpg_setup() {
	# GPG_TTY needs to be set or the passphrase prompt will not appear in terminal
	if ! grep -q GPG_TTY ~/.bashrc; then
		echo 'export GPG_TTY=$(tty)' >> ~/.bashrc
		export GPG_TTY=$(tty)
	fi

	# Verify a gpg key has been initialized
	local key='gpg --list-key "$USERNAME" 2> /dev/null | awk "/^pub/{getline;print}" | xargs'
	if ! gpg --list-key "$USERNAME" &> /dev/null; then
		local passphrase
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
		gpg --batch --passphrase "$passphrase" --quick-add-key $key rsa4096 default 0
	else
		key=$(eval $key)
	fi

	# Initalize pass using gpg key
	pass init $key
}


# Install dependencies required for docker-to-ghcr.sh
# (assuming a Debian based distro)
if ! which jq > /dev/null; then
	echo 'Installing jq...'
	sudo apt update && sudo apt install -y jq || exit 1
fi

if ! which pass > /dev/null; then
	echo 'Installing pass...'
	sudo apt update && sudo apt install -y pass || exit 1
fi

if ! which docker > /dev/null; then
	echo "Installing docker..."
	sudo apt update && sudo apt install -y \
		ca-certificates \
		curl \
		gnupg \
		lsb-release || exit $?

	# Add Docker’s official GPG key
	sudo mkdir -p /etc/apt/keyrings && \
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
		sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

	# Setup the repository
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
		https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
		| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

	# Install docker-ce
	sudo apt-get update && sudo apt-get install -y \
		docker-ce docker-ce-cli containerd.io || exit $?

	# Verify docker is working
	sudo docker run --rm hello-world || exit $?
	sudo docker rmi hello-world:latest

	# Setup so that Docker can be run without sudo
	sudo usermod -aG docker $USER || exit $?
fi

if ! which docker-credential-pass > /dev/null; then
	echo "Installing docker-credential-pass..."
	sudo curl -sSL https://github.com/docker/docker-credential-helpers/releases/download/v0.7.0/docker-credential-pass-v0.7.0.linux-$(dpkg --print-architecture) \
		-o /usr/local/bin/docker-credential-pass || exit $?
	jq -n '{"credsStore": "pass"}' > ~/.docker/config.json || exit $?
fi

gpg_setup
