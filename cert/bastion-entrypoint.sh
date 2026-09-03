#!/bin/sh
# Bastion container entrypoint (docker-compose.yml). Runs with the full
# container environment, so it materializes the config from .env into the files
# the wrapper reads (no-auth-ssh strips the session environment, so the wrapper
# can't read env vars itself), then hands off to tailcat.
set -e

apk add --no-cache openssh-client ca-certificates >/dev/null

# Wait for step-ca to have initialized (shared volume), then derive the CA
# fingerprint from its root cert unless one was pinned in .env.
for _ in $(seq 1 60); do [ -f /ca/certs/root_ca.crt ] && break; sleep 1; done
fp="${CA_FINGERPRINT:-$(step certificate fingerprint /ca/certs/root_ca.crt)}"

mkdir -p /etc/bastion
printf %s "$CA_URL" >/etc/bastion/ca-url
printf %s "$fp" >/etc/bastion/fingerprint
printf %s "$TARGET" >/etc/bastion/target
printf %s "$DEFAULT_METHOD" >/etc/bastion/default-method
printf %s "$OIDC_PROVISIONER" >/etc/bastion/oidc-provisioner
printf %s "$JWK_PROVISIONER" >/etc/bastion/jwk-provisioner
if [ -n "$PROVISIONER_PASSWORD" ]; then printf %s "$PROVISIONER_PASSWORD" >/etc/bastion/provisioner-password; fi
if [ -n "$CERT_PRINCIPALS" ]; then printf %s "$CERT_PRINCIPALS" >/etc/bastion/cert-principals; fi

export SHELL=/usr/local/bin/bastion
exec /opt/tailcat/tailcat serve --allow="$ALLOW_KEY" no-auth-ssh
