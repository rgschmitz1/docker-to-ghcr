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

set -eo pipefail

# Execute the cleanup function if user interrupts script (Ctrl+C)
trap cleanup 2

main() {
	# verify all required arguments are passed on the command line
	if [ -z "$1" ]; then
		prompt error "Docker username was not passed"
		usage 1
	elif [ "$1" = '-h' ] || [ "$1" = '--help' ]; then
		# allow -h|--help options to print usage without error
		usage 0
	fi
	DOCKER_USER=$1

	#if [ -z "$2" ]; then
	#	prompt error "Docker API key was not passed"
	#	usage 1
	#fi
	#DOCKER_KEY=$2

	if [ -z "$2" ]; then
		prompt error "GitHub username was not passed"
		usage 1
	fi
	GITHUB_USER=$2

	if [ -z "$3" ]; then
		prompt error "GitHub API key was not passed"
		usage 1
	fi
	GITHUB_KEY=$3

	# build a full image list from docker hub, cache locally incase we want to interrupt script
	FULL_IMAGE_LIST=/tmp/${DOCKER_USER}-docker-hub-image-list.txt

	# create temp file to store API JSON output
	JSON=$(mktemp)

	install_dependencies || cleanup 1

	if ! get_docker_hub_image_list; then
		prompt error "Encountered an issue generating container image list for $DOCKER_USER"
		rm -f $FULL_IMAGE_LIST
		cleanup 1
	fi

	ghcr_upload

	cleanup $?
}

# Print usage message then exit with status code
usage() {
	cat <<-USAGE
	usage: $(basename $0) <Docker username> <GitHub username> <GitHub API key>

	inputs:
	  Docker username - Source to generate container image list
	  GitHub username - Destination account to push container images
	  GitHub API key  - Authenticate user to push container images
	USAGE

	exit $1
}

# Remove temp files then exit with status code
cleanup() {
	[ -f "$JSON" ] && rm $JSON

	exit $1
}

# Colorized prompts
#
# Inputs
#   $1 - Status
#   $2 - Message
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

# Install dependencies required for script
# We are assuming a Debian based distro here
install_dependencies() {
	if ! which jq > /dev/null; then
		prompt info 'Installing jq...'
		sudo apt update && sudo apt install -y jq
		return $?
	fi

	return 0
}

# Get Docker token to allow for a higher rate limit when pulling info from registry
get_docker_token() {
	curl -sS -d '{"username":"'$DOCKER_USER'","password":"'$DOCKER_KEY'"}' "https://hub.docker.com/v2/users/login" > $JSON \
		|| cleanup 1
	local token=$(jq -r '.token' $JSON)
	echo $token
	[ -n "$token" ] && [ "$token" != 'null' ]

	return $?
}

# Generate full list of images for Docker user
get_docker_hub_image_list() {
	# Check if image list exists
	if [ -s "$FULL_IMAGE_LIST" ]; then
		prompt debug "Image list already exists, skipping lookup"
		return 0
	fi

	#local token=$(get_docker_token) || return $?

	# docker hub API
	local hub='https://hub.docker.com/v2/repositories'

	# partial curl command
	#local _curl="curl -sS -H 'Authorization: JWT $token'"
	local _curl="curl -sS"

	prompt info "Building full image list for $DOCKER_USER\n---"

	# get list of repos for that user account
	local repos=()
	local next="$hub/$DOCKER_USER/?page_size=100"
	while [ "$next" != "null" ]; do
		$_curl $next > $JSON || return 1
		repos+=($(jq -r '.results|.[]|.name' $JSON))
		next=$(jq -r '.next' $JSON)
	done

	# build a list of all images & tags
	local repo
	local tag
	for repo in ${repos[@]}; do
		# get tags for repo
		local tags=()
		next="$hub/$DOCKER_USER/$repo/tags/?page_size=100"
		while [ "$next" != "null" ]; do
			$_curl $next > $JSON || return 1
			tags+=($(jq -r '.results|.[]|.name' $JSON))
			next=$(jq -r '.next' $JSON)
		done

		# build a list of images from tags
		for tag in ${tags[@]}; do
			# add each tag to list
			echo $DOCKER_USER/$repo:$tag | tee -a $FULL_IMAGE_LIST
		done
	done

	return 0
}

check_if_exists_on_ghcr() {
	local image=$1
	local repo=$(echo $image | sed 's|.*/\(.*\):.*|\1|')
	local tag=$(echo $image | sed 's|.*:\(.*\)|\1|')
	image=$(echo $image | sed 's|:.*||')
	local schema="application/vnd.docker.distribution.manifest.v2+json"

	curl -sS -u $GITHUB_USER:$GITHUB_KEY "https://ghcr.io/token?scope=repository:$repo:pull" > $JSON \
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

ghcr_upload() {
	local docker_image
	while read -r docker_image; do
		# If image already exists on ghcr, skip
		if check_if_exists_on_ghcr "$docker_image"; then
			prompt debug "$docker_image already exists on ghcr... skipping"
			sed -i 1d ${FULL_IMAGE_LIST}
			continue
		fi

		if ! docker pull $docker_image; then
			prompt error "Encountered an issue pulling $docker_image"
			return 1
		fi

		# tag image for uploading to ghcr.io
		local ghcr_image="ghcr.io/$(echo $docker_image | sed "s|.*/|$GITHUB_USER/|")"
		docker tag $docker_image $ghcr_image

		# login to ghcr
		# TODO: ignore warning about insecure password, this can be fixed later
		echo $GITHUB_KEY | docker login ghcr.io -u $GITHUB_USER --password-stdin 2> /dev/null

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
