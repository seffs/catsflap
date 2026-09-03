#!/usr/bin/env bash
# Proves the pubkey path with no tailcat in the loop — just Docker:
#   client SSH key ──▶ bastion sshd (authkeys maps the key to a principal)
#                      └─ mint-and-proxy mints a short-lived cert for it
#                         └─▶ target sshd (trusts only the CA) → shell
# It runs the REAL authkeys.sh and mint-and-proxy.sh, and checks that a listed
# key lands as its principal while an unlisted key is refused.
# Run: ./verify-pubkey.sh   (needs Docker; leaves nothing behind).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

net=cfpk_net
cleanup() {
	docker rm -f cfpk_ca cfpk_target cfpk_bastion >/dev/null 2>&1 || true
	docker volume rm cfpk_data cfpk_keys >/dev/null 2>&1 || true
	docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker network create "$net" >/dev/null
docker volume create cfpk_data >/dev/null
docker volume create cfpk_keys >/dev/null

echo "== init step-ca (SSH CA, provisioner 'admin') =="
docker run --rm -v cfpk_data:/home/step --entrypoint sh smallstep/step-ca -c '
  mkdir -p /home/step/secrets && printf ca-pw > /home/step/secrets/password
  step ca init --ssh --deployment-type standalone --name "catsflap CA" \
    --dns localhost --dns step-ca --address :9000 \
    --provisioner admin --password-file /home/step/secrets/password \
    --provisioner-password-file /home/step/secrets/password >/dev/null 2>&1'

echo "== run step-ca =="
docker run -d --name cfpk_ca --network "$net" --network-alias step-ca \
	-v cfpk_data:/home/step smallstep/step-ca >/dev/null
for i in $(seq 1 15); do sleep 1; docker logs cfpk_ca 2>&1 | grep -q "Serving HTTPS" && break; done

echo "== run target sshd that trusts ONLY the CA (user 'demo') =="
docker run -d --name cfpk_target --network "$net" --network-alias target -v cfpk_data:/ca:ro debian:stable-slim sh -c '
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssh-server >/dev/null 2>&1
  cp /ca/certs/ssh_user_ca_key.pub /etc/ssh/user_ca.pub
  useradd -m -s /bin/bash demo && mkdir -p /run/sshd
  printf "TrustedUserCAKeys /etc/ssh/user_ca.pub\nPasswordAuthentication no\nAuthorizedKeysFile none\n" >> /etc/ssh/sshd_config
  exec /usr/sbin/sshd -D -e' >/dev/null
for i in $(seq 1 15); do sleep 1; docker logs cfpk_target 2>&1 | grep -q "Server listening" && break; done

echo "== make two client keys; map only the first to principal 'demo' =="
docker run --rm -v cfpk_keys:/keys alpine sh -c '
  apk add --no-cache openssh-keygen >/dev/null
  ssh-keygen -t ed25519 -N "" -f /keys/client   -C client   >/dev/null
  ssh-keygen -t ed25519 -N "" -f /keys/intruder -C intruder >/dev/null
  chmod 600 /keys/client /keys/intruder
  printf "demo %s\n" "$(cut -d" " -f1-2 /keys/client.pub)" > /keys/keymap
  echo "  keymap: $(cat /keys/keymap | cut -c1-60)..."'

echo "== run the bastion (real authkeys.sh + mint-and-proxy.sh; sshd front door) =="
docker run -d --name cfpk_bastion --network "$net" --network-alias bastion --user 0:0 \
	-v cfpk_data:/ca:ro -v cfpk_keys:/keys:ro \
	-v "$here/authkeys.sh:/in/authkeys:ro" \
	-v "$here/mint-and-proxy.sh:/in/mint-and-proxy:ro" \
	--entrypoint sh smallstep/step-cli -c '
  apk add --no-cache openssh >/dev/null
  mkdir -p /etc/catsflap
  printf %s https://step-ca:9000 > /etc/catsflap/ca-url
  printf %s "$(step certificate fingerprint /ca/certs/root_ca.crt)" > /etc/catsflap/fingerprint
  printf %s target > /etc/catsflap/target-host
  printf %s admin  > /etc/catsflap/jwk-provisioner
  printf %s ca-pw  > /etc/catsflap/ca-pw
  cp /keys/keymap /etc/catsflap/keymap
  chmod 0644 /etc/catsflap/ca-url /etc/catsflap/fingerprint /etc/catsflap/target-host /etc/catsflap/jwk-provisioner /etc/catsflap/keymap
  cp /in/authkeys /usr/local/bin/authkeys && cp /in/mint-and-proxy /usr/local/bin/mint-and-proxy
  chown root:root /usr/local/bin/authkeys /usr/local/bin/mint-and-proxy
  chmod 0755 /usr/local/bin/authkeys /usr/local/bin/mint-and-proxy
  adduser -D -s /bin/sh catsflap
  sed -i "/^catsflap:/ s/^catsflap:[^:]*:/catsflap:*:/" /etc/shadow
  chown catsflap /etc/catsflap/ca-pw && chmod 0400 /etc/catsflap/ca-pw
  ssh-keygen -A >/dev/null && mkdir -p /var/empty
  printf "Port 22\nPubkeyAuthentication yes\nPasswordAuthentication no\nAuthorizedKeysFile none\nAuthorizedKeysCommand /usr/local/bin/authkeys %%u %%t %%k\nAuthorizedKeysCommandUser root\nAllowUsers catsflap\nPermitTTY yes\n" > /etc/ssh/sshd_config
  exec /usr/sbin/sshd -D -e' >/dev/null
for i in $(seq 1 15); do sleep 1; docker logs cfpk_bastion 2>&1 | grep -q "Server listening" && break; done

sshc() { docker run --rm --network "$net" -v cfpk_keys:/keys:ro debian:stable-slim sh -c "
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssh-client >/dev/null 2>&1
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /keys/$1 catsflap@bastion \
    'echo OK whoami=\$(whoami)' 2>&1"; }

echo "== listed key (client) should land as demo =="
out=$(sshc client || true); echo "    ${out##*$'\n'}"
echo "== unlisted key (intruder) should be refused =="
bad=$(sshc intruder || true); echo "    ${bad##*$'\n'}"

echo
case "$out" in *"OK whoami=demo"*) ok=1 ;; *) ok=0 ;; esac
case "$bad" in *"OK whoami=demo"*) ok=0 ;; *"Permission denied"*) : ;; *) : ;; esac
if [ "$ok" = 1 ] && [[ "$bad" != *"OK whoami=demo"* ]]; then
	echo "== PASS: SSH key -> principal -> cert -> real sshd; unlisted key refused =="
else
	echo "== FAIL =="; exit 1
fi
