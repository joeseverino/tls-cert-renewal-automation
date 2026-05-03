# TLS Cert Renewal Automation

One command to issue or renew a Let's Encrypt wildcard certificate, deploy it to a cPanel server through cPanel UAPI, and verify both public edge TLS and origin-side SSL inventory.

Stack: Certbot + Cloudflare DNS-01 + SSH + cPanel UAPI + OpenSSL

---

## What this does

This project automates the full TLS renewal workflow for a cPanel-hosted site using Cloudflare-managed DNS.

It handles:

- Requesting or renewing a Let's Encrypt certificate with Certbot
- Completing DNS-01 validation through Cloudflare
- Supporting wildcard certificates
- Installing the certificate into cPanel through UAPI
- Verifying public TLS status with OpenSSL
- Showing cPanel origin SSL inventory through UAPI
- Separating Cloudflare edge certificate status from cPanel origin certificate status

This matters because when using Cloudflare proxy:

- Visitors see Cloudflare’s edge certificate
- Cloudflare connects to your server using your origin certificate

This script verifies both.

---

## Architecture

Browser
  ↓
Cloudflare edge TLS certificate
  ↓
Cloudflare proxy
  ↓
cPanel origin TLS certificate
  ↓
Website

---

## Prerequisites

Install locally:

- certbot
- certbot-dns-cloudflare
- curl
- openssl
- python3
- ssh

macOS example:

brew install certbot
pip install certbot-dns-cloudflare

You also need:

- Cloudflare managing DNS for your domains
- Cloudflare API token with DNS edit permissions
- SSH access to your cPanel server
- uapi available on the server

---

## Cloudflare API token

Create a token using the “Edit zone DNS” template.

Permissions:

Zone → DNS → Edit
Zone → Zone → Read

Scope it only to your domains.

---

## Setup

cp config.env.example config.env
chmod +x renew.sh

Edit config.env:

CERTBOT_EMAIL="you@example.com"
CERT_NAME="jseverino-origin"

CERTBOT_DOMAINS="jseverino.com *.jseverino.com jseverino.net *.jseverino.net"

CLOUDFLARE_API_TOKEN="your_token_here"

SSH_HOST="my-cpanel"

CPANEL_DOMAINS="jseverino.net test.jseverino.net quiz.jseverino.net"

VERIFY_DOMAINS="jseverino.com jseverino.net joeseverino.com"

---

## Config notes

- Wildcards do NOT cover apex domains
- *.jseverino.com does not include jseverino.com
- VERIFY_DOMAINS checks public TLS, not origin TLS
- Cloudflare credentials are generated at runtime

---

## Usage

./renew.sh check
sudo ./renew.sh dry-run
./renew.sh ssl-status
sudo ./renew.sh run
./renew.sh verify

---

## Commands

check
Validates config, dependencies, Cloudflare token, SSH, and cPanel UAPI

dry-run
Runs full staging validation (no real cert issued)

run
Issues/renews cert, installs it, then runs full status check

verify
Checks public TLS only using OpenSSL

ssl-status
Shows BOTH:

Public edge TLS (Cloudflare):

- subject
- issuer (typically Google Trust Services)
- expiration
- SANs
- days remaining

cPanel origin SSL inventory:

- installed hosts
- stored certificates
- issuer (Let’s Encrypt)
- expiration
- validation type
- SAN coverage

---

## Example output

Public edge TLS:

jseverino.com
Status: VALID
Issuer: Google Trust Services
Days left: 69

Origin SSL:

jseverino.com
Status: VALID
Issuer: Let's Encrypt E7
Days left: 85
Domains: *.jseverino.com, *.jseverino.net, jseverino.com, jseverino.net

---

## Renewal strategy

Let's Encrypt certs last 90 days.

Renew at ~60 days.

ssl-status shows both edge and origin timing so you can verify everything is aligned.

---

## Notes

- Edge and origin certificates will NOT match — that is expected
- Cloudflare always serves its own certificate to users
- Your script manages the origin certificate used between Cloudflare and your server
- If a domain fails in VERIFY_DOMAINS, it is not reachable over HTTPS or not configured

---

## Summary

This script gives you:

- Fully automated wildcard certificate issuance
- Secure DNS validation through Cloudflare
- Automated deployment to cPanel
- Clear visibility into both edge and origin TLS layers

This is not just renewal — it is full TLS lifecycle automation.
