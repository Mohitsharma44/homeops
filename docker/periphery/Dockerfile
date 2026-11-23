# syntax=docker/dockerfile:1.7
ARG PERIPHERY_TAG=latest
FROM ghcr.io/moghtech/komodo-periphery:${PERIPHERY_TAG}

# Install sops and age
# Digests from the projects' published checksums (sops checksums.txt, age release asset digest).
ADD --checksum=sha256:e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64 /usr/local/bin/sops
ADD --checksum=sha256:cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10 https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-linux-amd64.tar.gz /tmp/age.tar.gz
RUN chmod +x /usr/local/bin/sops && \
    tar -xzf /tmp/age.tar.gz -C /tmp && \
    mv /tmp/age/age /usr/local/bin/age && \
    mv /tmp/age/age-keygen /usr/local/bin/age-keygen && \
    rm -rf /tmp/age /tmp/age.tar.gz

COPY scripts/sops-decrypt.sh /usr/local/bin/sops-decrypt.sh
RUN chmod +x /usr/local/bin/sops-decrypt.sh
