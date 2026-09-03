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

# Persist the tailcat server key so the address stays stable across restarts.
# DERP_HOST set -> bake your own relay into the key (see README "Bring your own
# DERP"); empty -> pick the nearest public DERP region and fix it. The region is
# part of the address, so it must be pinned either way. `down -v` wipes the key.
keyfile=/var/lib/tailcat/server.private.json
region="--fixed-region"; [ -n "${DERP_HOST:-}" ] && region="--region=$DERP_HOST"
# shellcheck disable=SC2086
[ -f "$keyfile" ] || /opt/tailcat/tailcat genkey --key="$keyfile" $region >/dev/null
exec /opt/tailcat/tailcat serve --key="$keyfile" --allow="$ALLOW_KEY" no-auth-ssh
