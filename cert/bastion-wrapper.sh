#!/bin/sh
# $SHELL for the bastion's `tailcat serve no-auth-ssh`. It obtains a short-lived
# SSH certificate and makes the real login to the target sshd (which trusts only
# the CA and verifies offline). Two ways to get the certificate:
#
#   OIDC  — a person logs in through your IdP (step ssh login --console). Pick it
#           per connection with `--oidc`, or set default-method=oidc.
#   JWK   — a shared provisioner password. Pick it with `--jwk`, or connect
#           interactively when default-method=jwk. The password is read from a
#           mounted file if present (automation); otherwise it is prompted —
#           masked when the connection has a terminal, read from stdin when piped.
#
# The client also picks the target user; the certificate's principals decide
# whether it's allowed (sshd enforces it). Usage from the client:
#
#   tailcat ssh <addr>                     interactive: prompts for the user
#                                          (Enter = default) and, for JWK, the password
#   tailcat ssh <addr> alice --oidc        as alice via OIDC (named, no prompt)
#   echo "$PW" | tailcat ssh <addr> a --jwk run as alice via JWK, password piped
#
# Config files under /etc/bastion: ca-url, fingerprint, target (default
# `user@host`), default-method (oidc|jwk), oidc-provisioner, jwk-provisioner,
# and optionally provisioner-password (file) and cert-principals (comma list).
set -e
conf() { cat "/etc/bastion/$1" 2>/dev/null || true; }
export STEPPATH="$(mktemp -d)"

target="$(conf target)"
host="${target#*@}"
defuser="${target%@*}"
method="$(conf default-method)"
[ -n "$method" ] || method=oidc

user="$defuser"
cmd=""
if [ "$1" = "-c" ]; then
	req="$2"
	user="${req%% *}"
	rest="${req#"$user"}"
	rest="${rest# }"
	case "$rest" in
	--oidc | --oidc\ *) method=oidc; rest="${rest#--oidc}"; rest="${rest# }" ;;
	--jwk | --jwk\ *) method=jwk; rest="${rest#--jwk}"; rest="${rest# }" ;;
	esac
	cmd="$rest"
elif [ -t 0 ]; then
	# interactive: prompt for the user (Enter keeps the default)
	printf "User [%s]: " "$defuser" >&2
	IFS= read -r ans
	[ -n "$ans" ] && user="$ans"
fi
[ -n "$user" ] || user="$defuser"

step ca bootstrap --ca-url "$(conf ca-url)" --fingerprint "$(conf fingerprint)" -f >/dev/null 2>&1

ident=""
if [ "$method" = jwk ]; then
	if [ -s /etc/bastion/provisioner-password ]; then
		pwfile=/etc/bastion/provisioner-password
	else
		pwfile="$STEPPATH/pw"
		if [ -t 0 ]; then
			printf "Introduce password to unlock CA: " >&2
			stty -echo 2>/dev/null
			IFS= read -r pw
			stty echo 2>/dev/null
			echo >&2
		else
			IFS= read -r pw
		fi
		printf %s "$pw" >"$pwfile"
	fi
	principals="$(conf cert-principals)"
	pargs=""
	if [ -n "$principals" ]; then
		oldifs="$IFS"; IFS=,
		for p in $principals; do pargs="$pargs --principal $p"; done
		IFS="$oldifs"
	else
		pargs="--principal $user"
	fi
	# shellcheck disable=SC2086
	step ssh certificate "$defuser" "$STEPPATH/id" --provisioner "$(conf jwk-provisioner)" \
		--provisioner-password-file "$pwfile" $pargs --not-after 10m --no-password --insecure >/dev/null 2>&1
	ident="-i $STEPPATH/id"
else
	eval "$(ssh-agent -s)" >/dev/null
	step ssh login --provisioner "$(conf oidc-provisioner)" --console
fi

# shellcheck disable=SC2086
if [ -n "$cmd" ]; then
	exec ssh $ident -o StrictHostKeyChecking=accept-new "$user@$host" "$cmd"
else
	exec ssh -tt $ident -o StrictHostKeyChecking=accept-new "$user@$host"
fi
