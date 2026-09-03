#!/usr/bin/env bash
# Self-contained quickstart: brings up the whole chain in containers — step-ca,
# a demo target sshd that trusts the CA, and the tailcat bastion — and prints a
# tailcat address. From any machine with the tailcat CLI you then run
# `tailcat ssh <addr>` and land in the demo sshd, authenticated by a short-lived
# certificate. Touches nothing on the host.
#
#   ./quickstart.sh up      # bring it up, print the address (default)
#   ./quickstart.sh test    # connect a throwaway client and assert it works (JWK mode)
#   ./quickstart.sh down    # tear everything down
#
# Two modes:
#   JWK  (default)  — certificates minted with a password provisioner. No IdP
#                     needed; `test` can drive the whole flow.
#   OIDC (set the three OIDC_* vars) — a person logs in through your IdP (any
#                     OIDC provider with a device-flow client) before a cert is issued:
#       OIDC_ISSUER=https://idp.example.com \
#       OIDC_CLIENT_ID=... OIDC_CLIENT_SECRET=... ./quickstart.sh up
#     The connect step opens a browser, so it can't self-test; connect by hand.
#
# See QUICKSTART.md to graduate to your real host sshd.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
[ -f "$here/.env" ] && { set -a; . "$here/.env"; set +a; } # optional: OIDC_* etc.
net=ssca_qs
capw=ca-pw

mode=jwk
if [ -n "${OIDC_ISSUER:-}" ]; then
	mode=oidc
	: "${OIDC_CLIENT_ID:?set OIDC_CLIENT_ID for OIDC mode}"
	: "${OIDC_CLIENT_SECRET:?set OIDC_CLIENT_SECRET for OIDC mode}"
fi

addr_of() { docker logs ssca_qs_bastion 2>&1 | grep -oE 'tc[A-Za-z0-9_-]+' | head -1; }

down() {
	docker rm -f ssca_qs_ca ssca_qs_sshd ssca_qs_bastion >/dev/null 2>&1 || true
	docker volume rm ssca_qs_data ssca_qs_bin >/dev/null 2>&1 || true
	docker network rm "$net" >/dev/null 2>&1 || true
}

run_test() {
	local addr out
	addr="$(addr_of)"
	[ -n "$addr" ] || { echo "bastion isn't running — run '$0 up' first"; return 1; }
	if [ -n "$(docker inspect -f '{{index .Config.Labels "ssca.mode"}}' ssca_qs_bastion 2>/dev/null | grep oidc)" ]; then
		echo "OIDC mode needs an interactive browser login, so it can't self-test."
		echo "Connect by hand:  tailcat ssh $addr   (then approve in your browser)"
		return 0
	fi
	echo "== connecting a throwaway tailcat client to the bastion =="
	out="$(timeout 60 docker run --rm --network "$net" -v ssca_qs_bin:/usr/local/bin:ro alpine:3.22 sh -c '
	  apk add --no-cache openssh-client >/dev/null 2>&1
	  tailcat ssh '"$addr"' demo "echo RESULT whoami=\$(whoami) host=\$(hostname)" 2>/dev/null')" || true
	echo "$out" | tail -1 | sed 's/^/    /'
	case "$out" in
	*"RESULT whoami=demo"*) echo "== PASS: connected over tailcat and landed as demo via certificate ==" ;;
	*) echo "== FAIL =="; return 1 ;;
	esac
}

case "${1:-up}" in
down) down; echo "torn down."; exit 0 ;;
test) run_test; exit $? ;;
up) ;;
*) echo "usage: $0 [up|test|down]"; exit 2 ;;
esac
down
# --ipv6 so this works on IPv6-only hosts (NAT64), where an IPv4-only
# user-defined network has no upstream. Falls back on non-IPv6 daemons.
docker network create --ipv6 "$net" >/dev/null 2>&1 || docker network create "$net" >/dev/null
docker volume create ssca_qs_data >/dev/null
docker volume create ssca_qs_bin >/dev/null

echo "== 1/5 init + run step-ca (SSH CA; mode: $mode) =="
docker run --rm -v ssca_qs_data:/home/step --entrypoint sh smallstep/step-ca -c "
  mkdir -p /home/step/secrets && printf %s '$capw' > /home/step/secrets/password
  step ca init --ssh --deployment-type standalone --name 'Quickstart CA' \
    --dns step-ca --dns localhost --address :9000 \
    --provisioner admin --password-file /home/step/secrets/password \
    --provisioner-password-file /home/step/secrets/password >/dev/null 2>&1"
docker run -d --name ssca_qs_ca --network "$net" --network-alias step-ca \
	-v ssca_qs_data:/home/step smallstep/step-ca >/dev/null
for i in $(seq 1 15); do sleep 1; docker logs ssca_qs_ca 2>&1 | grep "Serving HTTPS" >/dev/null && break; done
fp="$(docker run --rm -v ssca_qs_data:/ca:ro --entrypoint step smallstep/step-ca \
	certificate fingerprint /ca/certs/root_ca.crt)"

if [ "$mode" = oidc ]; then
	echo "== 1b/5 add OIDC provisioner 'oidc' (issuer must be reachable) =="
	docker run --rm -v ssca_qs_data:/home/step --entrypoint step smallstep/step-ca \
		ca provisioner add oidc --type OIDC \
		--client-id "$OIDC_CLIENT_ID" --client-secret "$OIDC_CLIENT_SECRET" \
		--configuration-endpoint "${OIDC_ISSUER%/}/.well-known/openid-configuration"
	docker restart ssca_qs_ca >/dev/null
	for i in $(seq 1 15); do sleep 1; docker logs ssca_qs_ca 2>&1 | grep "Serving HTTPS" >/dev/null && break; done
fi

echo "== 2/5 demo target sshd (trusts the CA; any authenticated identity -> user 'demo') =="
# AuthorizedPrincipalsCommand echoes the cert key-id, which step-ca sets to the
# identity and also lists as a principal — so any CA-signed cert (JWK 'demo' or
# an OIDC email) logs in as demo. Keeps the demo working in both modes.
docker run -d --name ssca_qs_sshd --network "$net" -v ssca_qs_data:/ca:ro debian:stable-slim sh -c '
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssh-server >/dev/null 2>&1
  cp /ca/certs/ssh_user_ca_key.pub /etc/ssh/user_ca.pub
  useradd -m -s /bin/bash demo && mkdir -p /run/sshd
  printf "TrustedUserCAKeys /etc/ssh/user_ca.pub\nPasswordAuthentication no\nAuthorizedPrincipalsCommand /bin/echo %%i\nAuthorizedPrincipalsCommandUser nobody\n" >> /etc/ssh/sshd_config
  exec /usr/sbin/sshd -D -e' >/dev/null

echo "== 3/5 seed the tailcat binary from the official image =="
docker run --rm -v ssca_qs_bin:/usr/local/bin ghcr.io/tailscale/tailcat:latest version >/dev/null

echo "== 4/5 write bastion config =="
cfg="$(mktemp -d)"
printf https://step-ca:9000 >"$cfg/ca-url"
printf %s "$fp" >"$cfg/fingerprint"
printf demo@ssca_qs_sshd >"$cfg/target"
if [ "$mode" = oidc ]; then
	printf oidc >"$cfg/default-method"
	printf oidc >"$cfg/oidc-provisioner"
else
	printf jwk >"$cfg/default-method"
	printf admin >"$cfg/jwk-provisioner"
	printf %s "$capw" >"$cfg/provisioner-password" # file present -> non-interactive
fi
wrapper=bastion-wrapper.sh

echo "== 5/5 start the tailcat bastion =="
docker run -d --name ssca_qs_bastion --network "$net" --user 0:0 \
	--label "ssca.mode=$mode" \
	-v ssca_qs_bin:/opt/tailcat:ro \
	-v "$here/$wrapper":/usr/local/bin/bastion:ro \
	-v "$cfg":/etc/bastion:ro \
	--entrypoint sh smallstep/step-cli -c '
	  apk add --no-cache openssh-client ca-certificates >/dev/null
	  export SHELL=/usr/local/bin/bastion
	  exec /opt/tailcat/tailcat serve no-auth-ssh' >/dev/null

echo "   waiting for the demo sshd and the bastion to be ready..."
for i in $(seq 1 40); do sleep 1; docker logs ssca_qs_sshd 2>&1 | grep "Server listening" >/dev/null && break; done
for i in $(seq 1 20); do sleep 1; docker logs ssca_qs_bastion 2>&1 | grep "new address" >/dev/null && break; done
addr="$(addr_of)"

echo
echo "=================================================================="
echo " Bastion is up (mode: $mode). From any machine with the tailcat CLI:"
echo
echo "     tailcat ssh $addr"
echo
if [ "$mode" = oidc ]; then
	echo " You'll be prompted to log in via your IdP (a URL is printed);"
	echo " approve it in a browser and a short-lived cert lands you in the"
	echo " demo sshd. (No self-test in OIDC mode — the login needs a browser.)"
else
	echo " You'll land in the demo sshd as 'demo', authenticated by a"
	echo " short-lived certificate."
	echo
	echo " Or verify it from here:  ./quickstart.sh test"
fi
echo " Tear down:               ./quickstart.sh down"
echo "=================================================================="
