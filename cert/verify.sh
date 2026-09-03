#!/usr/bin/env bash
# Proves the certificate mechanics this project relies on, with no OIDC and no
# tailcat in the loop — just: step-ca issues a short-lived SSH user certificate,
# and an sshd that trusts only the CA (TrustedUserCAKeys, no authorized_keys)
# accepts a login with it. The OIDC and tailcat layers sit in front of exactly
# this. Run: ./verify.sh   (needs Docker; leaves nothing behind).
set -euo pipefail

net=ssca_verify_net
cleanup() {
	docker rm -f ssca_verify_ca ssca_verify_sshd >/dev/null 2>&1 || true
	docker volume rm ssca_verify_data ssca_verify_out >/dev/null 2>&1 || true
	docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# --ipv6 so this works on IPv6-only hosts (NAT64), where an IPv4-only
# user-defined network has no upstream. Falls back on non-IPv6 daemons.
docker network create --ipv6 "$net" >/dev/null 2>&1 || docker network create "$net" >/dev/null
docker volume create ssca_verify_data >/dev/null
docker volume create ssca_verify_out >/dev/null

echo "== init step-ca with the SSH CA enabled =="
docker run --rm -v ssca_verify_data:/home/step --entrypoint sh smallstep/step-ca -c '
  mkdir -p /home/step/secrets && printf ca-pw > /home/step/secrets/password
  step ca init --ssh --deployment-type standalone --name "Verify CA" \
    --dns localhost --dns step-ca --address :9000 \
    --provisioner admin --password-file /home/step/secrets/password \
    --provisioner-password-file /home/step/secrets/password >/dev/null 2>&1
  echo "  SSH user CA (goes on hosts as TrustedUserCAKeys):"
  sed "s/^/    /" /home/step/certs/ssh_user_ca_key.pub'

echo "== run step-ca =="
docker run -d --name ssca_verify_ca --network "$net" --network-alias step-ca \
	-v ssca_verify_data:/home/step smallstep/step-ca >/dev/null
for i in $(seq 1 15); do sleep 1; docker logs ssca_verify_ca 2>&1 | grep -q "Serving HTTPS" && break; done

echo "== run an sshd that trusts ONLY the CA (no authorized_keys) =="
docker run -d --name ssca_verify_sshd --network "$net" -v ssca_verify_data:/ca:ro debian:stable-slim sh -c '
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssh-server >/dev/null 2>&1
  cp /ca/certs/ssh_user_ca_key.pub /etc/ssh/user_ca.pub
  useradd -m -s /bin/bash demo && mkdir -p /run/sshd
  printf "TrustedUserCAKeys /etc/ssh/user_ca.pub\nPasswordAuthentication no\nAuthorizedKeysFile none\n" >> /etc/ssh/sshd_config
  exec /usr/sbin/sshd -D -e' >/dev/null
for i in $(seq 1 15); do sleep 1; docker logs ssca_verify_sshd 2>&1 | grep -q "Server listening" && break; done

echo "== mint a 10-minute SSH cert for principal 'demo' =="
docker run --rm --network "$net" -v ssca_verify_data:/ca:ro -v ssca_verify_out:/out \
	--entrypoint sh smallstep/step-ca -c '
  export STEPPATH=/tmp/s; mkdir -p $STEPPATH
  step ca bootstrap --ca-url https://step-ca:9000 \
    --fingerprint "$(step certificate fingerprint /ca/certs/root_ca.crt)" >/dev/null 2>&1
  printf ca-pw > /tmp/pw
  step ssh certificate demo /out/id_demo --provisioner admin --provisioner-password-file /tmp/pw \
    --principal demo --not-after 10m --no-password --insecure >/dev/null 2>&1
  chmod 600 /out/id_demo
  step ssh inspect /out/id_demo-cert.pub | grep -iE "Key ID|Principals|Valid" | sed "s/^/    /"'

echo "== log in with ONLY the certificate =="
out=$(docker run --rm --network "$net" -v ssca_verify_out:/out debian:stable-slim sh -c '
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssh-client >/dev/null 2>&1
  ssh -o StrictHostKeyChecking=no -i /out/id_demo demo@ssca_verify_sshd \
    "echo OK whoami=\$(whoami)" 2>/dev/null')
echo "    $out"
case "$out" in
*"OK whoami=demo"*) echo "== PASS: cert-only login works ==" ;;
*) echo "== FAIL =="; exit 1 ;;
esac
