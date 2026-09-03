#!/bin/sh
# catsflap — pubkey bastion entrypoint.
#
# A real sshd is the front door. Clients authenticate with an SSH key; the key
# is mapped to a principal (authkeys), a short-lived cert is minted for it
# (mint-and-proxy), and the login is proxied to the target host's real sshd.
# tailcat is the transport and --allow still gates which device may reach it.
set -e

apk add --no-cache openssh >/dev/null

# Wait for step-ca (shared volume) so we can derive the CA fingerprint.
for _ in $(seq 1 60); do [ -f /ca/certs/root_ca.crt ] && break; sleep 1; done

# Materialize config into files the forced command reads (sshd sanitizes the
# session environment, so mint-and-proxy can't inherit these as env vars).
mkdir -p /etc/catsflap
printf %s "$CA_URL" >/etc/catsflap/ca-url
printf %s "${CA_FINGERPRINT:-$(step certificate fingerprint /ca/certs/root_ca.crt)}" >/etc/catsflap/fingerprint
printf %s "$TARGET_HOST" >/etc/catsflap/target-host
printf %s "$JWK_PROVISIONER" >/etc/catsflap/jwk-provisioner
printf %s "$CA_PASSWORD" >/etc/catsflap/ca-pw
cp /etc/catsflap-in/keymap /etc/catsflap/keymap
chmod 0644 /etc/catsflap/ca-url /etc/catsflap/fingerprint /etc/catsflap/target-host /etc/catsflap/jwk-provisioner /etc/catsflap/keymap

# The single login account clients land on (identity comes from the key, not
# this name). ca-pw is readable only by it.
adduser -D -s /bin/sh catsflap 2>/dev/null || true
# adduser leaves the account password-locked ("!"), which OpenSSH refuses even
# for pubkey auth ("account is locked"); set it to disabled-but-not-locked ("*").
sed -i '/^catsflap:/ s/^catsflap:[^:]*:/catsflap:*:/' /etc/shadow
chown catsflap /etc/catsflap/ca-pw && chmod 0400 /etc/catsflap/ca-pw

# sshd requires AuthorizedKeysCommand (and its dirs) to be root-owned and not
# group/world-writable, so install the helpers into place rather than run the
# bind-mounted copies directly.
cp /usr/local/bin/authkeys.in /usr/local/bin/authkeys
cp /usr/local/bin/mint-proxy.in /usr/local/bin/mint-and-proxy
chown root:root /usr/local/bin/authkeys /usr/local/bin/mint-and-proxy
chmod 0755 /usr/local/bin/authkeys /usr/local/bin/mint-and-proxy

# Front-door sshd: pubkey only; the key -> principal mapping is authkeys.
ssh-keygen -A >/dev/null
mkdir -p /var/empty
cat >/etc/ssh/sshd_config <<EOF
Port ${SSHD_PORT:-22}
PubkeyAuthentication yes
PasswordAuthentication no
AuthenticationMethods publickey
AuthorizedKeysFile none
AuthorizedKeysCommand /usr/local/bin/authkeys %u %t %k
AuthorizedKeysCommandUser root
AllowUsers catsflap
PermitTTY yes
EOF
/usr/sbin/sshd -e

# Persist the tailcat server key so the address stays stable across restarts.
# DERP_HOST set -> bake your own relay into the key (see README "Bring your own
# DERP"); empty -> pick the nearest public DERP region and fix it. Either way the
# region is part of the address, so it must be pinned. `down -v` wipes the key.
keyfile=/var/lib/tailcat/server.private.json
region="--fixed-region"; [ -n "${DERP_HOST:-}" ] && region="--region=$DERP_HOST"
# shellcheck disable=SC2086
[ -f "$keyfile" ] || /opt/tailcat/tailcat genkey --key="$keyfile" $region >/dev/null

# tailcat serves the sshd port over the tunnel, gated by --allow.
exec /opt/tailcat/tailcat serve --key="$keyfile" --allow="$ALLOW_KEY" "${SSHD_PORT:-22}"
