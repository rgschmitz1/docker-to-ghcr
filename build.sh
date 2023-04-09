#!/bin/bash

case $(uname -m) in
	x86_64)
		ARCH='amd64'
		;;
	aarch64)
		ARCH='arm64'
		;;
	*)
		echo "Unsupported CPU architecture"
		exit 1
		;;
esac

while [ -z "$PASSPHRASE" ]; do
	read -rsp "Enter a passphrase: " PASSPHRASE
	echo
	read -rsp "Re-enter passphrase: "
	echo
	[ "$PASSPHRASE" != "$REPLY" ] && unset PASSPHRASE
done

read -rp "Enter a username (e.g. John Doe): " USERNAME
echo

read -rp "Enter an email (e.g. jdoe@example.com): " EMAIL
echo

docker build --tag docker-to-ghcr \
	--build-arg ARCH=$ARCH \
	--build-arg PASSPHRASE=$PASSPHRASE \
	--build-arg USERNAME=$USERNAME \
	--build-arg EMAIL=$EMAIL .
