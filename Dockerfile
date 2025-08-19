FROM ghcr.io/celestiaorg/celestia-app:latest AS celestia-app

FROM ghcr.io/celestiaorg/celestia-node:latest

USER root

# hadolint ignore=DL3018
RUN apk --no-cache add \
        curl \
        jq \
        openssl \
    && mkdir /bridge \
    && chown celestia:celestia /bridge

USER celestia

COPY --from=celestia-app /bin/celestia-appd /bin/

COPY entrypoint.sh /opt/entrypoint.sh

# Expose ports:
# 26657 - Validator RPC
# 26658 - Bridge RPC
# 26659 - Bridge Gateway
# 9090  - Validator gRPC
EXPOSE 26657 26658 26659 9090

ENTRYPOINT [ "/bin/bash", "/opt/entrypoint.sh" ]
