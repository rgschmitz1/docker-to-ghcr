#!/bin/bash

###
# Backup from Docker container registry to GitHub container registry
#
# Author: Bob Schmitz
#
# History:
#  2023-04-05 - Check if container image already exists in GHCR using API
#  2023-04-04 - Initial creation
###

set -e

main() {
	# Verify all required arguments are passed on the command line
	if [ -z "${1}" ]; then
		echo "Docker username was not passed"
		usage
		exit 1
	fi
	local docker_user=${1}

	if [ -z "${2}" ]; then
		echo "GitHub username was not passed"
		usage
		exit 1
	fi
	local github_user=${2}

	if [ -z "${3}" ]; then
		echo "GitHub API key was not passed"
		usage
		exit 1
	fi
	local github_key=${3}

	# We will build a full image list from docker hub, cache locally incase we want to interrupt script
	FULL_IMAGE_LIST=/tmp/${docker_user}-docker-hub-image-list.txt

	install_dependencies

	get_docker_hub_image_list ${docker_user}

	ghcr_upload ${github_user} ${github_key}
}

usage() {
	cat <<-USAGE
	usage: $(basename $0) <Docker username> <GitHub username> <GitHub API key>

	inputs:
	  Docker username - Source to generate container image list
	  GitHub username - Destination account to push container images
	  GitHub API key  - Authenticate user to push container images
	USAGE
}

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

	# docker hub html
	local hub='https://hub.docker.com/v2/repositories'

	# username on docker hub
	local username=${1}

	# partial curl command for Docker hub authorization
	local _curl="curl -s ${hub}/${username}"

	printf "Building full image list\n---\n\n"

	# get list of repos for that user account
	local repo_list=$($_curl/?page_size=10000 | jq -r '.results|.[]|.name')

	# build a list of all images & tags
	local i
	local j
	for i in ${repo_list}; do
		# get tags and sha256 hash for repos
		local image_tags=$($_curl/${i}/tags/?page_size=10000 | jq -r '.results|.[]|.name')
	
		# build a list of images from tags
		for j in ${image_tags}; do
			# add each tag to list
			echo ${username}/${i}:${j} | tee -a $FULL_IMAGE_LIST
		done
	done
}

check_if_exists_on_ghcr() {
	local username=$1
	local cr_pat=$2
	local image=$3
	local repo=$(echo $image | sed 's|.*/\(.*\):.*|\1|')
	local tag=$(echo $image | sed 's|.*:\(.*\)|\1|')
	image=$(echo $image | sed 's|:.*||')
	local github_token=$(curl -s -u $username:$cr_pat https://ghcr.io/token\?scope\=repository:$repo:pull | jq -r '.token')
	local github_digest=$(curl -s -H "Authorization: Bearer $github_token" https://ghcr.io/v2/$username/$repo/manifests/$tag | jq -r '.config.digest')
	local docker_token=$(curl -sSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$image:pull" | jq -r '.token')
	local docker_digest=$(curl -sL -H "Authorization: Bearer $docker_token" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" https://registry.hub.docker.com/v2/$image/manifests/$tag | jq -r '.config.digest')

	# if Docker and GitHub container registry digests match
	[ "$docker_digest" = "$github_digest" ] && return 0 || return 1
}

ghcr_upload() {
	local username=${1}
	local cr_pat=${2}
	local i
	while read -r i; do
		# If image already exists on ghcr, skip
		if check_if_exists_on_ghcr "$username" "$cr_pat" "$i"; then
			echo "$i already exists on ghcr... skipping"
			sed -i 1d ${FULL_IMAGE_LIST}
			continue
		fi

		if ! docker pull $i; then
			echo "Encountered error pulling $i"
			exit 1
		fi

		# tag image for uploading to ghcr.io
		local ghcr_image="ghcr.io/$(echo $i | sed "s|.*/|$username/|")"
		docker tag $i $ghcr_image

		# login to ghcr
		# (ignore warning about insecure password, this can be fixed later)
		echo $cr_pat | docker login ghcr.io -u $username --password-stdin 2> /dev/null

		# push image to ghcr.io
		if docker push $ghcr_image; then
			sed -i 1d ${FULL_IMAGE_LIST}
			docker rmi $i $ghcr_image
		else
			echo "Encountered and error pushing $ghcr_image"
			exit 1
		fi
	done < ${FULL_IMAGE_LIST}
	rm ${FULL_IMAGE_LIST}
}

main "${1}" "${2}" "${3}"
