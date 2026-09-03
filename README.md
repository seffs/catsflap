# catsflap

*A CA-powered SSH bastion stack for your tailcat(s)*

---

## TL;DR

You already use `tailcat`: no open ports, no accounts, no keys to upload. With
the `catsflap` stack, each login mints a **short-lived SSH certificate** — from
an OIDC identity, a JWK password, or an SSH key — that a real `sshd` verifies
offline.

- **composable infrastructure** — manage access from wherever you manage your containers
- **client allowlist** — only your `--allow`ed device can reach it
- **unprivileged container** — no `--privileged`, no host-namespace escape
- **no long-lived credentials** — certs live minutes; nothing standing to steal

---

## Stacks

catsflap ships two stacks — same tailcat transport, same short-lived-cert-into-a-
real-`sshd` tail, different front door. Pick by how a caller proves who they are:

| stack | caller proves identity with | needs | best when |
|-------|------------------------------|-------|-----------|
| [**cert/**](./cert/) | an **OIDC** login, or a **JWK** password | an IdP (OIDC) or a shared password (JWK) | you want IdP-backed identity, or a quick shared-secret setup |
| [**pubkey/**](./pubkey/) | an **SSH key** on an allowlist | nothing external — just the key | per-user identity with no IdP and no shared secret |

Each stack is a self-contained Docker Compose project with its own README,
`.env.example`, and a `verify*.sh` proof.   

> New here? Start in [`cert/`](./cert/) —
its [QUICKSTART](./cert/QUICKSTART.md) brings up a self-contained stack in one
command, no IdP required — or go straight to [`pubkey/`](./pubkey/).

## Why

catsflap is a plain Docker Compose stack, so your SSH access control becomes a
managed workload like any other — deployed, updated, watched, and torn down from
whatever runs your containers (Arcane, Portainer, Komodo, Dockge, GitOps, or bare
`docker compose`). It opens no ports and has no control plane of its own, so *who
can reach a host* lives in the same place, and the same version control, as the
services it protects. It fits especially well when:

- **the host is hard to reach** — CGNAT or no port-forward at home; edge/IoT boxes
  with no static IP. Portless reach over tailcat, no router changes.
- **you want zero open ports** — bind `sshd` to localhost; the only way in is the
  tunnel plus a valid cert. Nothing for scanners to find.
- **access should be temporary** — break-glass (`up` to enter, `down` after) or
  contractors granted and revoked entirely in your IdP, no `authorized_keys` churn.
- **you manage many hosts from one dashboard** — a bastion per host, one shared CA,
  a uniform set of "access" stacks instead of a full access platform.

## Why not

catsflap reassembles, over tailcat, what
[Teleport](https://goteleport.com/) or step-ca-with-a-bastion give you out of the
box: an identity (OIDC) or a shared provisioner secret (JWK) → short-lived SSH
certificates → real sshd. Reach for something simpler if:

- **You don't need the transport.** The host already has reachable, hardened SSH
  (a public IP, a VPN, or you're already on Tailscale) — the portless, no-account
  reach is moot, and plain step-ca or your existing setup is less to run.
- **You don't want to run a CA.** Short-lived certs mean operating step-ca and its
  lifecycle; if that's more infrastructure than you want, plain keys or an
  integrated product is less to own. *(catsflap attempts to keep this as simple as possible!)*
- **The host must stay untouched.** The target still has to trust the CA and carry
  a matching login account; if even that host-side change is off-limits, an
  agent-based tool fits better.
- **You need fleet-scale access management.** Central RBAC, inventory, session
  recording, access reviews, org-wide policy — that's Teleport (or Tailscale SSH)
  or a PAM platform. catsflap is deliberately host-oriented, not a global
  access-control plane.

The trade-off is intentional: catsflap favors simple, Docker-native ownership over
centralized management — own the whole stack yourself, and keep the target's SSH
boringly standard.

## Bring your own DERP (for scale)

catsflap's transport is tailcat, which by default relays through **Tailscale's
public DERP servers**. 

Run your own DERP (Tailscale's [`derper`](https://pkg.go.dev/tailscale.com/cmd/derper)
is open source) and point catsflap at it by baking your relay into the bastion's
server key — in the entrypoint, generate the key with `--region` instead of
`--fixed-region`:

```sh
tailcat genkey --key="$keyfile" --region=derp.example.com
```

The DERP host is then embedded in the tailcat address, so clients reach it with
no extra config. (Alternatively, set `TAILCAT_DERPMAP_URL` to a custom DERP map
for the bastion and clients.) None of this is needed for personal use — the
default relays work out of the box.

## License & attribution

catsflap is licensed under the [Apache License 2.0](./LICENSE). It orchestrates —
but does not include or redistribute — [tailcat](https://github.com/tailscale/tailcat)
(BSD 3-Clause, Tailscale Inc.) and [step-ca](https://github.com/smallstep/certificates)
(Apache 2.0, Smallstep); see [NOTICE](./NOTICE).

"Tailscale" and "Tailcat" are trademarks of Tailscale Inc. catsflap is an
independent project and is **not affiliated with or endorsed by Tailscale Inc.** —
references to tailcat describe interoperability only.
