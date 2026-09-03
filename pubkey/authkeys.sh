#!/bin/sh
# sshd AuthorizedKeysCommand for the catsflap pubkey bastion.
# Invoked by sshd as: authkeys <user> <keytype> <keybase64>
#
# It looks the offered key up in the keymap. On a match it emits a single
# authorized_keys line that (a) forces mint-and-proxy for that key's principal
# and (b) locks the session down to nothing else. No match => no output => the
# key is rejected. The mapping — not the login user — decides the identity.
#
# keymap lines: <principal> <keytype> <keybase64> [comment]   ('#' and blanks ok)
keytype="$2"
keyb64="$3"
keymap=/etc/catsflap/keymap
[ -f "$keymap" ] || exit 0

while read -r principal t k _rest; do
	case "$principal" in '' | \#*) continue ;; esac
	if [ "$t" = "$keytype" ] && [ "$k" = "$keyb64" ]; then
		printf 'restrict,pty,command="/usr/local/bin/mint-and-proxy %s" %s %s\n' \
			"$principal" "$keytype" "$keyb64"
		exit 0
	fi
done <"$keymap"
exit 0
