# TLS Cert Renewal Automation

Automates Let's Encrypt wildcard certificate issuance and renewal, deploys certificates to cPanel via UAPI, and provides visibility into both public (Cloudflare edge) and origin TLS.

Stack: Certbot + Cloudflare DNS-01 + SSH + cPanel UAPI + OpenSSL

---

## Overview

This project provides end-to-end automation for managing TLS certificates on cPanel-hosted sites using Cloudflare-managed DNS.

Features:

- Automated Let's Encrypt certificate issuance and renewal
- DNS-01 validation through Cloudflare (supports wildcards)
- Deployment to cPanel via UAPI over SSH
- Public TLS verification using OpenSSL
- Origin SSL inventory via cPanel UAPI
- Clear separation between Cloudflare edge certificates and origin certificates

When Cloudflare proxy is enabled:

- Visitors are served Cloudflare’s edge certificate
- Cloudflare connects to the origin server using the origin certificate

This project validates both layers.

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

Example (macOS):

    brew install certbot
    pip install certbot-dns-cloudflare

Additional requirements:

- Cloudflare managing DNS for target domains
- Cloudflare API token with DNS edit permissions
- SSH access to the cPanel server
- uapi available on the remote system

---

## Cloudflare API Token

Create an API token using the Edit zone DNS template.

Required permissions:

    Zone → DNS → Edit
    Zone → Zone → Read

Scope the token to the required zone(s) only.

---

## Setup

    cp config.env.example config.env
    chmod +x renew.sh

Edit config.env:

    CERTBOT_EMAIL="you@example.com"
    CERT_NAME="example-origin"

    CERTBOT_DOMAINS="example.com *.example.com"

    CLOUDFLARE_API_TOKEN="your_token_here"

    SSH_HOST="cpanel-host"

    CPANEL_DOMAINS="example.com sub.example.com"

    VERIFY_DOMAINS="example.com sub.example.com"

---

## Configuration Notes

- Wildcards do NOT include apex domains
- *.example.com does not include example.com
- VERIFY_DOMAINS checks public TLS (Cloudflare edge if proxied)
- Cloudflare credentials are generated at runtime and not stored

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
Validates configuration, dependencies, Cloudflare token, SSH, and cPanel UAPI

dry-run
Runs full staging validation (no real certificate issued)

run
Issues or renews certificate, installs it, and runs status verification

verify
Checks public TLS using OpenSSL

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

## Example Output

Public edge TLS:

    example.com
    Status: VALID
    Issuer: Google Trust Services
    Days left: 69

Origin SSL:

    example.com
    Status: VALID
    Issuer: Let's Encrypt
    Days left: 85
    Domains: *.example.com, example.com

---

## Renewal Strategy

Let's Encrypt certificates are valid for 90 days.

Renew around 60 days.

Use ssl-status to verify both edge and origin certificate timing.

---

## Notes

- Edge and origin certificates will not match; this is expected
- Cloudflare always serves its own certificate to visitors
- This script manages the origin certificate used between Cloudflare and the server
- If a domain fails verification, it is not reachable over HTTPS or not configured

---

## Summary

This project provides:

- Automated wildcard certificate issuance
- Secure DNS validation through Cloudflare
- Automated deployment to cPanel via UAPI
- Visibility into both edge and origin TLS layers

This is full TLS lifecycle automation, not just certificate renewal.
