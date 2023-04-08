#!/bin/bash

# Backup from Docker container registry to GitHub container registry
#
# Author: Bob Schmitz
#
# History:
#  2023-04-06 - Adding documentation and error checking
#  2023-04-05 - Check if container image already exists in GHCR using API
#  2023-04-04 - Initial creation


# Exit when errors encountered, return status from first pipe failure
set -eo pipefail

# Execute the cleanup function if user interrupts script (Ctrl-C)
trap cleanup 2


# Install and setup dependencies
./install-dependencies.sh || exit 1


# Main function
#
# Inputs:
#   $1 - Docker namespace
#   $2 - GitHub user
#   $3 - GitHub API key
main() {
	# verify all required arguments are passed on the command line
	if [ -z "$1" ]; then
		prompt error "Docker namespace was not passed"
		usage 1
	elif [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
		# allow -h|--help options to print usage without error
		usage 0
	fi
	DOCKER_NAMESPACE=$1

	if [ -z "$2" ]; then
		prompt error "GitHub username was not passed"
		usage 1
	fi
	GITHUB_USER=$2

	# build a full image list from docker hub,
	# cache locally in-case we want to interrupt script
	FULL_IMAGE_LIST=/tmp/${DOCKER_NAMESPACE}-docker-hub-image-list.txt

	# create temp file to store API JSON output
	JSON=$(mktemp)

	verify_pass_setup

	if ! get_docker_hub_image_list; then
		prompt error "Encountered an issue generating container image list for $DOCKER_NAMESPACE"
		rm -f $FULL_IMAGE_LIST
		cleanup 1
	fi

	ghcr_upload

	cleanup $?
}


# Script usage
#
# Inputs:
#   $1 - exit status
#
# Outputs:
#   Usage message
usage() {
	cat <<-USAGE
	usage: $(basename $0) <Docker namespace> <GitHub username> <Docker username>

	inputs:
	  Docker namespace - Source to generate container image list
	  GitHub username  - GitHub account to push container images
	  Docker username  - Docker account login name
                         (to increase rate-limit on pull request)
	USAGE

	exit $1
}


# Remove temp files then exit with status code
#
# Inputs:
#   $1 - exit status
cleanup() {
	[ -f "$JSON" ] && rm $JSON

	exit $1
}


# Colorized prompts
#
# Inputs:
#   $1 - Status
#   $2 - Message
#
# Output:
#   Colorful message to stdout
prompt() {
	local status=$1
	local msg="$2"

	# ASCII codes to colorize prompts
	local yellow='\033[1;33m'
	local red='\033[0;31m'
	local cyan='\033[0;36m'
	local nc='\033[0m'

	case $status in
		debug)
			printf "${yellow}${msg}${nc}\n"
		;;
		info)
			printf "${cyan}${msg}${nc}\n"
		;;
		error)
			printf "${red}ERROR: ${msg}${nc}\n"
		;;
	esac
}


# Check/Initialize pass store
verify_pass_setup() {
	# Check if github/GITHUB_USER is valid
	if ! pass github/$GITHUB_USER > /dev/null; then
		prompt info "Enter ghcr.io $GITHUB_USER API key"
		pass insert github/$GITHUB_USER
	fi
}


# Generate full list of images for Docker user
#
# Inputs:
#   DOCKER_NAMESPACE - Docker namespace to pull image list
#
# Output:
#   FULL_IMAGE_LIST - list of all public Docker hub images with tags
#
# Return:
#   0 if successful, otherwise error status
get_docker_hub_image_list() {
	# Check if image list exists
	if [ -s "$FULL_IMAGE_LIST" ]; then
		prompt debug "Image list already exists, skipping lookup"
		return 0
	fi

	# docker hub API
	local hub='https://hub.docker.com/v2/repositories'

	prompt info "Building full image list for $DOCKER_NAMESPACE\n---"

	# get list of repos for that user account
	local repos=()
	local next="$hub/$DOCKER_NAMESPACE/?page_size=100"
	while [ "$next" != "null" ]; do
		curl -sS $next > $JSON || return 1
		repos+=($(jq -r '.results|.[]|.name' $JSON))
		next=$(jq -r '.next' $JSON)
	done

	# build a list of all images & tags
	local repo
	local tag
	for repo in ${repos[@]}; do
		# get tags for repo
		local tags=()
		next="$hub/$DOCKER_NAMESPACE/$repo/tags/?page_size=100"
		while [ "$next" != "null" ]; do
			curl -sS $next > $JSON || return 1
			tags+=($(jq -r '.results|.[]|.name' $JSON))
			next=$(jq -r '.next' $JSON)
		done

		# build a list of images from tags
		for tag in ${tags[@]}; do
			# add each tag to list
			echo $DOCKER_NAMESPACE/$repo:$tag | tee -a $FULL_IMAGE_LIST
		done
	done

	return 0
}


# Check if container image already exists on ghcr
#
# Inputs:
#   $1 - Docker image
#
# Return:
#   0 if successful, otherwise error status
check_if_exists_on_ghcr() {
	local image=$1
	local repo=$(echo $image | sed 's|.*/\(.*\):.*|\1|')
	local tag=$(echo $image | sed 's|.*:\(.*\)|\1|')
	image=$(echo $image | sed 's|:.*||')
	local schema='application/vnd.docker.distribution.manifest.v2+json'

	curl -sS -u $GITHUB_USER:$(pass github/$GITHUB_USER) "https://ghcr.io/token?scope=repository:$repo:pull" > $JSON \
		|| cleanup $?
	local github_token=$(jq -r '.token' $JSON 2> /dev/null) || return $?

	curl -sS -H "Authorization: Bearer $github_token" "https://ghcr.io/v2/$GITHUB_USER/$repo/manifests/$tag" > $JSON \
		|| cleanup $?
	local github_digest=$(jq -r '.config.digest' $JSON 2> /dev/null) || return $?

	curl -sSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$image:pull" > $JSON \
		|| cleanup $?
	local docker_token=$(jq -r '.token' $JSON 2> /dev/null) || return $?

	curl -sSL -H "Authorization: Bearer $docker_token" -H "Accept: $schema" "https://registry.hub.docker.com/v2/$image/manifests/$tag" > $JSON \
		|| cleanup $?
	local docker_digest=$(jq -r '.config.digest' $JSON 2> /dev/null) || return $?

	# if Docker and GitHub container registry digests match
	[ -n "$docker_digest" ] && [ "$docker_digest" != 'null' ] && [ "$docker_digest" = "$github_digest" ]

	return $?
}


# GHCR image upload
#
# Inputs:
#   FULL_IMAGE_LIST - List of all Docker container images
#   GITHUB_USER     - GitHub user
#   GITHUB_KEY      - GitHub API key
#
# Return:
#   0 if successful, otherwise error status
ghcr_upload() {
	local docker_image
	while read -r docker_image; do
		# If image already exists on ghcr, skip
		if check_if_exists_on_ghcr "$docker_image"; then
			prompt debug "$docker_image already exists on ghcr... skipping"
			sed -i 1d ${FULL_IMAGE_LIST}
			continue
		fi

		docker login || return 1
		if ! docker pull $docker_image; then
			prompt error "Encountered an issue pulling $docker_image"
			return 1
		fi

		# tag image for uploading to ghcr.io
		local ghcr_image="ghcr.io/$(echo $docker_image | sed "s|.*/|$GITHUB_USER/|")"
		docker tag $docker_image $ghcr_image

		# login to ghcr
		echo $(pass github/$GITHUB_USER) | docker login ghcr.io -u $GITHUB_USER --password-stdin || return 1

		# push image to ghcr.io
		if ! docker push $ghcr_image; then
			prompt error "Encountered an issue pushing $ghcr_image"
			return 1
		fi
		sed -i 1d ${FULL_IMAGE_LIST}
		docker rmi $docker_image $ghcr_image
	done < ${FULL_IMAGE_LIST}
	rm ${FULL_IMAGE_LIST}

	return 0
}


main $@
