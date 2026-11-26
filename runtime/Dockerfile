ARG MIHOMO_IMAGE=docker.io/metacubex/mihomo:v1.19.24
FROM ${MIHOMO_IMAGE}
RUN apk add --no-cache iproute2
COPY --chmod=755 network.sh /usr/local/bin/network
ENTRYPOINT ["/usr/local/bin/network"]
