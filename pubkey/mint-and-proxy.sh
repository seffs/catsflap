#!/bin/sh
# Forced command for an authenticated key. authkeys bakes the principal in as
# command="mint-and-proxy <principal>", so sshd runs this with the identity the
# key is mapped to. It mints a short-lived SSH certificate for that principal
# from step-ca, then logs in to the target host's real sshd with it.
#
# The client never sees the CA password — its SSH key is the whole credential.
set -e
principal="$1"
[ -n "$principal" ] || { echo "catsflap: no principal for this key" >&2; exit 1; }

conf() { cat "/etc/catsflap/$1"; }
export STEPPATH="$(mktemp -d)"
id="$STEPPATH/id"

step ca bootstrap --ca-url "$(conf ca-url)" --fingerprint "$(conf fingerprint)" -f >/dev/null 2>&1
step ssh certificate "$principal" "$id" \
	--provisioner "$(conf jwk-provisioner)" --provisioner-password-file /etc/catsflap/ca-pw \
	--principal "$principal" --not-after 10m --no-password --insecure >/dev/null 2>&1

host="$(conf target-host)"
if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
	exec ssh -i "$id" -o StrictHostKeyChecking=accept-new "$principal@$host" "$SSH_ORIGINAL_COMMAND"
else
	exec ssh -tt -i "$id" -o StrictHostKeyChecking=accept-new "$principal@$host"
fi
