ARG PERIPHERY_TAG=latest
FROM ghcr.io/moghtech/komodo-periphery:${PERIPHERY_TAG}

# Install sops and age
ADD https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64 /usr/local/bin/sops
ADD https://github.com/FiloSottile/age/releases/download/v1.2.1/age-v1.2.1-linux-amd64.tar.gz /tmp/age.tar.gz
RUN chmod +x /usr/local/bin/sops && \
    tar -xzf /tmp/age.tar.gz -C /tmp && \
    mv /tmp/age/age /usr/local/bin/age && \
    mv /tmp/age/age-keygen /usr/local/bin/age-keygen && \
    rm -rf /tmp/age /tmp/age.tar.gz

COPY scripts/sops-decrypt.sh /usr/local/bin/sops-decrypt.sh
RUN chmod +x /usr/local/bin/sops-decrypt.sh
