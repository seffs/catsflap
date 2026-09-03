# Security Policy

catsflap is security tooling — it fronts SSH access to real hosts — so please
report suspected vulnerabilities **privately**, not in a public issue.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: the repository's **Security** tab →
**Report a vulnerability** (enable it under *Settings → Advanced Security* if it
isn't already). That opens a private advisory visible only to the maintainers.

Please include: what you found, how to reproduce it, and the impact. This is a
small project, so expect best-effort acknowledgement and no guaranteed timeline —
but security reports are taken seriously and prioritized over other work.

## Scope

In scope: the catsflap scripts, entrypoints, and Compose definitions — for
example the handling of the CA password, the `keymap` → principal mapping, the
`AuthorizedKeysCommand`/forced-command flow, and the `--allow` gating.

Out of scope: vulnerabilities in the upstream components catsflap invokes
(tailcat, step-ca, OpenSSH, Docker). Report those to their respective projects.
Also out of scope: misconfigurations of your own deployment (an over-broad
`keymap`, a weak `CA_PASSWORD`, a target host that trusts the wrong CA).

## Hardening reminders

- Keep `--allow` set to your real client key(s); don't run a bastion open.
- Use a long, random `CA_PASSWORD`; it stays server-side but is the key to minting.
- Keep certificate lifetimes short (the defaults are minutes).
- Treat the bastion as a trusted component and the `keymap`/`.env` as secrets
  (they are gitignored for this reason).
