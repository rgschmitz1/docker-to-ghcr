FROM alpine:3.17.1

LABEL org.opencontainers.image.source=https://github.com/rgschmitz1/docker-to-ghcr
LABEL org.opencontainers.image.licenses=MIT

ARG ARCH

# install dependencies
RUN apk add --no-cache \
	bash \
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
	&& mkdir -p $HOME/.docker \
	&& jq -n '{"credsStore": "pass"}' > ~/.docker/config.json

COPY docker-to-ghcr.sh /usr/local/bin
COPY install-dependencies.sh /usr/local/bin
COPY install-docker.sh /usr/local/bin

ENTRYPOINT ["docker-to-ghcr.sh"]
