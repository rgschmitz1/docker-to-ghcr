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

docker build --pull --tag docker-to-ghcr --build-arg ARCH=$ARCH .
