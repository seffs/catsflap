# Quickstart

Two ways to try this, both runnable in minutes. Everything here works the same
on your laptop and on a VPS — a step runs wherever you point Docker.

You'll need:

- **Docker** on the machine running the stack (laptop or VPS).
- The **tailcat CLI** on whatever machine you connect *from*
  (`go install github.com/tailscale/tailcat/cmd/tailcat@latest`, or see the
  [tailcat README](https://github.com/tailscale/tailcat#install)).

> [!NOTE]
> By default the quickstart uses **JWK (password) certificates** — no IdP needed
> to see the whole chain, and `./quickstart.sh test` can drive it end to end. Set
> the `OIDC_*` vars ([step 2](#with-oidc-if-you-have-idp-credentials)) to switch
> to a real OIDC login instead. Either way the bastion has no `--allow`, so anyone
> with the printed address can connect — it's for testing; add `--allow` before it
> guards anything real.

## 1. Smoke test: does the certificate mechanism work here? (~1 min)

Proves the core with no tailcat and no OIDC: step-ca issues a short-lived SSH
cert, and an sshd that trusts only the CA accepts a login with it.

```sh
./verify.sh
# ... == PASS: cert-only login works ==
```

Run it on the VPS too — if it passes there, the host can do certificate logins.

## 2. Full chain, self-contained (~2 min)

Brings up step-ca + a demo target sshd + the tailcat bastion, all in containers,
and prints a tailcat address. Nothing on the host is touched.

On the VPS (or locally):

```sh
./quickstart.sh up
# ...
#     tailcat ssh tcXXXXXXXX
```

From your laptop, with the printed address:

```sh
tailcat ssh tcXXXXXXXX
# lands you in the demo sshd as 'demo', authenticated by a short-lived cert
tailcat ssh tcXXXXXXXX demo 'whoami; hostname'   # first arg is the user; -> demo  <container id>
```

That's the real product path: tailcat address (no open ports, no IP) → bastion →
a certificate minted per login → a real sshd login.

Or let it prove itself — this spins up a throwaway tailcat client, connects, and
checks it landed as `demo`:

```sh
./quickstart.sh test
# == PASS: connected over tailcat and landed as demo via certificate ==
```

Tear it down with:

```sh
./quickstart.sh down
```

### With OIDC (if you have IdP credentials)

Same self-contained stack, but a person logs in through your IdP before a
certificate is issued. Give it your device-flow client's issuer, id, and secret:

```sh
OIDC_ISSUER=https://idp.example.com \
OIDC_CLIENT_ID=... OIDC_CLIENT_SECRET=... ./quickstart.sh up

tailcat ssh <addr>    # prints a sign-in URL — approve it in your browser, then you're in
```

`quickstart.sh` adds an OIDC provisioner to step-ca (your issuer must be
reachable — it's validated when added) and runs the bastion with the OIDC
wrapper. The login needs a browser, so `./quickstart.sh test` can't drive it —
connect by hand. The demo sshd accepts any authenticated identity as `demo`, so
you don't have to line up principals just to try it (for a real host, see
[step 4](#4-add-oidc)).

## Choosing which user you connect as

The client names the target user as the first argument, and the certificate's
principals decide whether it's allowed — the bastion doesn't:

```sh
tailcat ssh <addr>                  # interactive: prompts "User [default]:" (Enter = default)
tailcat ssh <addr> alice           # interactive as alice (named, no prompt)
tailcat ssh <addr> alice uptime    # run `uptime` as alice
```

Requesting a user never grants access: sshd only lets you become `alice` if the
certificate carries the `alice` principal (from your OIDC identity, or the
bastion's `cert-principals` in JWK mode). [`verify-user-select.sh`](./verify-user-select.sh)
proves it — with a cert scoped to `alice,bob`, connecting as `alice` or `bob`
works and `carol` is refused:

```sh
./verify-user-select.sh
#     alice -> alice
#     bob   -> bob
#     carol -> <refused>
#  == PASS: client picks the user; the certificate's principals enforce it ==
```

### Choosing the auth method per connection

After the user, a client can pick how the certificate is obtained — overriding
the bastion's `DEFAULT_METHOD`:

```sh
tailcat ssh <addr> alice --oidc          # log in through the IdP
tailcat ssh <addr>                       # interactive: prompts for user, then (JWK) a masked password
echo "$PW" | tailcat ssh <addr> a --jwk  # JWK, password piped (for scripts)
```

The JWK password is masked only on an interactive (bare) connection, which has a
terminal; the `--jwk` flag runs as a command (no terminal), so there the
password is piped or typed visibly. OIDC never needs a password — you approve
the printed URL in a browser.

## 3. Point it at your real host sshd

The quickstart above lands in a throwaway demo container. To reach the VPS's
*own* shell, run the main [`docker-compose.yml`](./docker-compose.yml) — it
brings up step-ca and the bastion, and the bastion is on `--network host` so
`TARGET=me@localhost` is the host's own sshd.

The order matters, and it answers the common question — **you trust the CA on
the host *after* `docker compose up`, because `up` is what creates the CA.** The
whole flow:

**a. Make a client key** on the machine you'll connect *from*. `--allow` gates
the bastion by client key, so the connecting machine needs a stable identity
whose public key you can allow-list. `--key=client-default` is the magic name
tailcat's client modes load automatically, so after this one command `tailcat
ssh` just works — no `--key` on every connect:

```sh
tailcat genkey --client --key=client-default
# nodekey:abcd…        <- this printed public key is your ALLOW_KEY
# (forgot it? re-print with `tailcat printpub`)
```

**b. Configure `.env`** on the machine running the stack. Set the four required
values; everything else has a sensible default (see [`.env.example`](./.env.example)):

```sh
cp .env.example .env
# ALLOW_KEY=nodekey:...   # the public key printed in step a
# CA_PASSWORD=...         # initializes and unlocks step-ca; also the JWK prompt answer
# TARGET=me@localhost     # user@host the bastion logs into; user is overridable per connection
# DEFAULT_METHOD=jwk      # jwk (CA password) or oidc (step 4)
```

**c. Bring it up.** step-ca **auto-initializes** on first `up` with the SSH CA
enabled, and the bastion derives the CA fingerprint itself from the shared
volume — nothing to copy by hand:

```sh
docker compose up -d
docker compose logs bastion | grep 'new address'   # -> tailcat ssh tcXXXXXXXX
```

**d. Now trust that CA on the host, once.** The CA exists only after step c, so
this comes last. Pull step-ca's SSH **user** CA key out of the running stack and
install it, then reload sshd:

```sh
docker compose exec -T step-ca cat /home/step/certs/ssh_user_ca_key.pub \
  | sudo tee /etc/ssh/step_user_ca.pub
sudo cp sshd-ca.conf /etc/ssh/sshd_config.d/ && sudo systemctl reload ssh
```

Make sure a login account exists whose name matches the certificate principal
(`me`, or whatever you connect as). That's the only host-side change — no
per-user keys, ever.

**e. Connect.** From the same machine as step a (it reuses `client-default`),
with the address from step c:

```sh
tailcat ssh <addr>                 # prompts for user (Enter = TARGET's) and the JWK password
tailcat ssh <addr> me uptime       # run `uptime` as me
```

## 4. Add OIDC

This builds on step 3's real-host deployment — the same
[`docker-compose.yml`](./docker-compose.yml) and
[`bastion-wrapper.sh`](./bastion-wrapper.sh) already do OIDC; you just add a
provisioner and flip the default method. It works with any OpenID Connect
provider that supports the **device authorization grant** ([RFC 8628](https://datatracker.ietf.org/doc/html/rfc8628)) —
the bastion is headless, so `step ssh login --console` uses the device flow. All
you need is that client's **issuer, client id, and client secret**.

**a. Add an OIDC provisioner to step-ca** (after `up`; the issuer must be
reachable — step validates it when you add it). `--ssh` sets `enableSSHCA`, which
lets the provisioner sign SSH certs:

```sh
docker compose exec step-ca step ca provisioner add oidc --type OIDC --ssh \
  --client-id "$OIDC_CLIENT_ID" --client-secret "$OIDC_CLIENT_SECRET" \
  --configuration-endpoint "https://idp.example.com/.well-known/openid-configuration"
docker compose restart step-ca
```

**b. Make OIDC the default.** In `.env` set `DEFAULT_METHOD=oidc` (and, if you
named the provisioner something other than `oidc`, `OIDC_PROVISIONER=<name>`),
then `docker compose up -d` to pick it up. The bastion's wrapper now runs
`step ssh login --provisioner oidc --console`, printing a URL for the user to
approve — no browser needed on the server. (A client can still pick per
connection with `tailcat ssh <addr> user --oidc` or `--jwk`.)

**c. Line up the principal with the account.** The certificate step-ca mints
carries the user's identity as its principal, and sshd logs in as the matching
account. Map them: configure the provisioner's SSH template (or `getSSHUser`) to
emit the right principal, or name the host account to match — otherwise sshd
rejects the certificate for the requested user.

Then connect, and you'll be asked to log in first:

```sh
client$ tailcat ssh <addr>
# To sign in, open: https://idp.example.com/device?user_code=WDJB-MJHT
# (approve in your browser; a short-lived cert is minted; sshd logs you in)
```

`--allow` still gates which device may reach the bastion, so a full connection
now needs an approved device *and* an authenticated person. Everything else —
the tunnel, the certificate-into-sshd login, the host trust — is exactly what
steps 2 and 3 already tested.

> [!NOTE]
> The `step ca provisioner add` command and the `--console` login are verified
> against the real tools, but the live device-flow login itself needs a running
> IdP, so it isn't exercised by `verify.sh` or `quickstart.sh` — those cover the
> certificate and tunnel halves.
