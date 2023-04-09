FROM alpine:3.17.1

LABEL org.opencontainers.image.source=https://github.com/rgschmitz1/docker-to-ghcr
LABEL org.opencontainers.image.licenses=MIT

ARG ARCH
ARG USERNAME
ARG EMAIL
ARG PASSPHRASE

# install dependencies
RUN apk add --no-cache \
	ca-certificates \
	curl \
	docker-cli \
	gnupg \
	jq \
	pass

# get the latest version of docker-credential-pass
RUN repo='docker/docker-credential-helpers' \
	&& ver=$(curl -sL https://api.github.com/repos/${repo}/releases/latest | jq -r '.tag_name') \
	&& curl -sS \
	https://github.com/${repo}/releases/download/${ver}/docker-credential-pass-${ver}.linux-$ARCH \
	-o /usr/local/bin/docker-credential-pass \
	&& chmod +x /usr/local/bin/docker-credential-pass \
	&& mkdir -p ~/.docker \
	&& jq -n '{"credsStore": "pass"}' > ~/.docker/config.json

COPY docker-to-ghcr.sh /usr/local/bin
COPY install-dependencies.sh /usr/local/bin
COPY install-docker.sh /usr/local/bin

# setup gpg key and pass
RUN install-dependencies.sh \
	&& pass init $(gpg --list-key "${USERNAME}" 2> /dev/null | awk "/^pub/{getline;print}" | xargs)

ENTRYPOINT ["docker-to-ghcr.sh"]
