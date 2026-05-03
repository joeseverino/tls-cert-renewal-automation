# TLS Cert Renewal Automation

One command to renew a Let's Encrypt wildcard certificate and deploy it to a cPanel server via the cPanel UAPI.

**Stack:** certbot + Cloudflare DNS plugin + SSH + cPanel UAPI

---

## Prerequisites

- [certbot](https://certbot.eff.org) installed locally (`brew install certbot`)
- [certbot-dns-cloudflare](https://certbot-dns-cloudflare.readthedocs.io) plugin (`pip install certbot-dns-cloudflare`)
- Cloudflare managing DNS for your domain(s)
- SSH access to your cPanel server configured in `~/.ssh/config`

---

## Setup

**1. Clone / copy this repo into a permanent location on your machine.**

**2. Create your config files:**

```bash
cp config.env.example config.env
cp cloudflare.ini.example cloudflare.ini
```

**3. Fill in `config.env`** — set your email, cert name, domains, SSH host, and cPanel domains. See the file for field descriptions.

**4. Fill in `cloudflare.ini`** — paste your Cloudflare API token:

```ini
dns_cloudflare_api_token = YOUR_TOKEN_HERE
```

Create the token at [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens) using the **Edit zone DNS** template, scoped to your domain(s).

**5. Make the script executable:**

```bash
chmod +x renew.sh
```

---

## Usage

```bash
./renew.sh check      # verify config, token, SSH, and cPanel — no changes
sudo ./renew.sh dry-run  # full certbot test against staging — no real cert
sudo ./renew.sh run      # renew and deploy  (default)
./renew.sh verify     # confirm the live cert on each domain
```

### Recommended first-run sequence

```bash
./renew.sh check
sudo ./renew.sh dry-run
sudo ./renew.sh run
./renew.sh verify
```

After setup, renewal is just:

```bash
tls run       # if you've added the shell function (see below)
tls verify
```

---

## How it works

1. **Renew** — certbot requests a certificate from Let's Encrypt using the DNS-01 challenge. The Cloudflare plugin automatically creates the required `_acme-challenge` TXT record and removes it after validation. Wildcards are supported.

2. **Deploy** — for each domain in `CPANEL_DOMAINS`, the script connects over SSH and calls `uapi SSL install_ssl` with the cert, private key, and CA bundle. cPanel writes the cert into its own store and reconfigures Apache — no manual file placement or service restarts needed.

3. **Verify** — `openssl s_client` connects to each domain in `VERIFY_DOMAINS` and prints the subject, issuer, SANs, and days until expiry.

---

## Shell function (zshrc)

See `.zshrc-snippet` for the function to add to your shell config.

---

## Renewal schedule

Let's Encrypt certificates expire after 90 days. Renew at ~60 days (30 days before expiry) to stay comfortable. The `verify` command will show you the days remaining at any time.
