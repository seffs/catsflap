# Quickstart — pubkey stack

Runnable in minutes. Everything here works the same on your laptop and on a VPS —
a step runs wherever you point Docker.

You'll need:

- **Docker** on the machine running the stack (laptop or VPS).
- The **tailcat CLI** on whatever machine you connect *from*
  (`go install github.com/tailscale/tailcat/cmd/tailcat@latest`, or see the
  [tailcat README](https://github.com/tailscale/tailcat#install)).
- An **SSH key** on the machine you connect from (`~/.ssh/id_ed25519`, or any
  key). Its *public* half goes in the bastion's `keymap` — that's your identity.

> [!NOTE]
> Two different keys are in play. The **tailcat node key** (`--allow`) gates which
> *device* may reach the bastion; your **SSH key** (`keymap`) is who you *are*
> once you're through. You need both.

## 1. Smoke test: does the key → cert path work here? (~1 min)

Proves the whole mechanism with no tailcat and no IdP: a listed SSH key is mapped
to a principal, a short-lived cert is minted for it, and a target sshd that trusts
only the CA accepts the login — while an unlisted key is refused.

```sh
./verify-pubkey.sh
# ...
#     OK whoami=demo
#     catsflap@bastion: Permission denied (publickey,keyboard-interactive).
# == PASS: SSH key -> principal -> cert -> real sshd; unlisted key refused ==
```

Run it on the VPS too — if it passes there, the host can do certificate logins.

## 2. Deploy against your real host

**a. Make a tailcat client key** on the machine you'll connect *from* (the device
gate). `--key=client-default` is the magic name tailcat loads automatically:

```sh
tailcat genkey --client --key=client-default
# nodekey:abcd…        <- this printed public key is your ALLOW_KEY
```

**b. Configure `.env`** on the machine running the stack:

```sh
cp .env.example .env
# ALLOW_KEY=nodekey:...        # the nodekey from step a
# CA_PASSWORD=...              # initializes + unlocks step-ca; stays server-side
# TARGET_HOST=host.docker.internal   # the target's real sshd (default: the Docker host)
```

**c. Map your SSH key to a principal.** Create your `keymap` from the tracked
template, then add one line per person, `<principal> <keytype> <key-base64>`:

```sh
cp keymap.example keymap
# take the type + key fields (drop the trailing comment) from your public key:
cut -d' ' -f1-2 ~/.ssh/id_ed25519.pub | sed 's/^/alice /' >> keymap
# -> alice ssh-ed25519 AAAAC3Nza...
```

**d. Bring it up.** step-ca auto-initializes; the bastion starts its sshd front
door and serves it over tailcat:

```sh
docker compose up -d
docker compose logs bastion | grep 'new address'   # -> tailcat ssh catsflap@tcXXXXXXXX
```

**e. Trust the CA on the host, once** (after `up` — the CA exists only once it's
created). Pull step-ca's SSH user CA key out of the running stack and install it:

```sh
docker compose exec -T step-ca cat /home/step/certs/ssh_user_ca_key.pub \
  | sudo tee /etc/ssh/step_user_ca.pub
sudo cp sshd-ca.conf /etc/ssh/sshd_config.d/ && sudo systemctl reload ssh
```

Make sure a login account exists for each principal you mapped (e.g. `alice`).
That's the only host-side change — no per-user keys, ever.

**f. Connect** with your own SSH key. You land on the target as the principal your
key maps to:

```sh
tailcat ssh catsflap@<addr>            # interactive
tailcat ssh catsflap@<addr> uptime     # run a command
```

> [!NOTE]
> Clients always log in to the bastion as the fixed account `catsflap` — the
> identity comes from your key, not this name — so connect as `catsflap@<addr>`.

## Adding and removing people

Edit [`keymap`](./keymap.example) and `docker compose up -d` — the bastion recreates and
re-reads it. Removing a line revokes that key immediately; the person's SSH key
never touched the host, and any cert they held expires within minutes.

## Many hosts

Point several hosts at the same CA (step e on each), run a bastion per host, and
share one `keymap` — a principal maps to a cert valid on every host that trusts
the CA. Manage them as a uniform set of Compose stacks (Arcane, Portainer, …).
