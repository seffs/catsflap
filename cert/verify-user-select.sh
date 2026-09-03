#!/usr/bin/env bash
# Proves option (b): the connecting client picks the target user
# (`tailcat ssh <addr> <user> ...`), and the certificate's principals — not the
# client's request — decide whether it's allowed. The bastion here issues certs
# scoped to principals [alice, bob], and the target sshd uses default principal
# matching (the login user must be a cert principal). So:
#     alice -> OK,  bob -> OK,  carol -> REFUSED.
# Self-contained; leaves nothing behind. Needs Docker.
set -euo pipefail
net=ussel; capw=pw
cleanup() {
	docker rm -f ussel_ca ussel_sshd ussel_bastion >/dev/null 2>&1 || true
	docker volume rm ussel_data ussel_bin >/dev/null 2>&1 || true
	docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
here="$(cd "$(dirname "$0")" && pwd)"
docker network create "$net" >/dev/null
docker volume create ussel_data >/dev/null
docker volume create ussel_bin >/dev/null

echo "== step-ca =="
docker run --rm -v ussel_data:/home/step --entrypoint sh smallstep/step-ca -c "
  mkdir -p /home/step/secrets && printf %s '$capw' > /home/step/secrets/password
  step ca init --ssh --deployment-type standalone --name U --dns step-ca --address :9000 \
    --provisioner admin --password-file /home/step/secrets/password \
    --provisioner-password-file /home/step/secrets/password >/dev/null 2>&1"
docker run -d --name ussel_ca --network "$net" --network-alias step-ca -v ussel_data:/home/step smallstep/step-ca >/dev/null
for i in $(seq 1 15); do sleep 1; docker logs ussel_ca 2>&1 | grep -q "Serving HTTPS" && break; done
fp="$(docker run --rm -v ussel_data:/ca:ro --entrypoint step smallstep/step-ca certificate fingerprint /ca/certs/root_ca.crt)"

echo "== strict sshd with accounts alice + bob (default principal matching; no carol) =="
docker run -d --name ussel_sshd --network "$net" -v ussel_data:/ca:ro debian:stable-slim sh -c '
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssh-server >/dev/null 2>&1
  cp /ca/certs/ssh_user_ca_key.pub /etc/ssh/user_ca.pub
  useradd -m -s /bin/bash alice && useradd -m -s /bin/bash bob && mkdir -p /run/sshd
  printf "TrustedUserCAKeys /etc/ssh/user_ca.pub\nPasswordAuthentication no\nAuthorizedKeysFile none\n" >> /etc/ssh/sshd_config
  exec /usr/sbin/sshd -D -e' >/dev/null

echo "== seed tailcat + start bastion (cert scoped to principals alice,bob) =="
docker run --rm -v ussel_bin:/usr/local/bin ghcr.io/tailscale/tailcat:latest version >/dev/null
cfg="$(mktemp -d)"
printf https://step-ca:9000 >"$cfg/ca-url"; printf %s "$fp" >"$cfg/fingerprint"
printf jwk >"$cfg/default-method"; printf admin >"$cfg/jwk-provisioner"
printf %s "$capw" >"$cfg/provisioner-password"  # file present -> non-interactive
printf alice@ussel_sshd >"$cfg/target"          # default user alice
printf alice,bob >"$cfg/cert-principals"        # authorized accounts
docker run -d --name ussel_bastion --network "$net" --user 0:0 \
	-v ussel_bin:/opt/tailcat:ro \
	-v "$here/bastion-wrapper.sh":/usr/local/bin/bastion:ro \
	-v "$cfg":/etc/bastion:ro \
	--entrypoint sh smallstep/step-cli -c '
	  apk add --no-cache openssh-client ca-certificates >/dev/null
	  export SHELL=/usr/local/bin/bastion
	  exec /opt/tailcat/tailcat serve no-auth-ssh' >/dev/null
for i in $(seq 1 40); do sleep 1; docker logs ussel_sshd 2>&1 | grep -q "Server listening" && break; done
for i in $(seq 1 20); do sleep 1; docker logs ussel_bastion 2>&1 | grep -q "new address" && break; done
addr="$(docker logs ussel_bastion 2>&1 | grep -oE 'tc[A-Za-z0-9_-]+' | head -1)"

ask() { # $1 = requested user
	timeout 60 docker run --rm --network "$net" -v ussel_bin:/usr/local/bin:ro alpine:3.22 sh -c '
	  apk add --no-cache openssh-client >/dev/null 2>&1
	  tailcat ssh '"$addr"' '"$1"' "whoami" 2>/dev/null' || true
}
echo "== connect as each user =="
a="$(ask alice)"; b="$(ask bob)"; c="$(ask carol)"
printf "    alice -> %s\n    bob   -> %s\n    carol -> %s\n" "${a:-<refused>}" "${b:-<refused>}" "${c:-<refused>}"
if [ "$a" = alice ] && [ "$b" = bob ] && [ -z "$c" ]; then
	echo "== PASS: client picks the user; the certificate's principals enforce it =="
else
	echo "== FAIL =="; exit 1
fi
