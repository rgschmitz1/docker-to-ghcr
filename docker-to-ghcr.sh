#!/bin/bash

set -e

FULL_IMAGE_LIST=/tmp/${1}-docker-hub-image-list.txt

install_dependencies() {
	if ! which jq > /dev/null; then
		echo 'Installing jq...'
		sudo apt update && sudo apt install -y jq
	fi
}

get_docker_hub_image_list() {
	# Check if image list exists
	if [ -s "$FULL_IMAGE_LIST" ]; then
		echo "Image list already exists, skipping lookup"
		return 0
	fi

	# Docker hub html
	local hub='https://hub.docker.com/v2/repositories'

	# User to search for
	local username=${1}

	# Put your own docker hub token.
	# You can use pass command or 1password cli to store pat 
	local token=${2}

	printf "Building full image list\n---\n\n"

	# get list of repos for that user account
	local repo_list=$(curl -s -H "Authorization: JWT ${token}" ${hub}/${username}/?page_size=10000 | jq -r '.results|.[]|.name')

	# build a list of all images & tags
	local i
	local j
	for i in ${repo_list}; do
		# get tags for repo
		local image_tags=$(curl -s -H "Authorization: JWT ${token}" ${hub}/${username}/${i}/tags/?page_size=10000 | jq -r '.results|.[]|.name')
	
		# build a list of images from tags
		for j in ${image_tags}; do
			# add each tag to list
			echo ${username}/${i}:${j} | tee -a $FULL_IMAGE_LIST
		done
	done
}

docker_image_pull() {
	local image=${i}
	if ! docker pull $image; then
		echo "Encountered error pulling $image"
		exit 1
	fi
	return $?
}

ghcr_upload() {
	local username=${1}
	local cr_pat=${2}
	local i
	while read -r i; do
		docker_image_pull $i
		# Tag image for uploading to ghcr.io
		local ghcr_image="ghcr.io/$(echo $i | sed "s|.*/|$username/|")"
		docker tag $i $ghcr_image
		echo $cr_pat | docker login ghcr.io -u $username --password-stdin
		if docker push $ghcr_image; then
			sed -i 1d ${FULL_IMAGE_LIST}
			docker rmi $i $ghcr_image
		else
			echo "Encountered and error pushing $i to ghcr"
			exit 1
		fi
	done < ${FULL_IMAGE_LIST}
	rm ${FULL_IMAGE_LIST}
}

install_dependencies

get_docker_hub_image_list ${1} ${2}

ghcr_upload ${3} ${4}
