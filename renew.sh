#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
CF_INI=""  # written at runtime from CLOUDFLARE_API_TOKEN in config.env

USAGE="Usage: $(basename "$0") [check | dry-run | verify | run]

  check    — test config, Cloudflare token, SSH, and cPanel UAPI (no changes)
  dry-run  — full certbot dry run against staging (no real cert issued)
  verify   — check the live TLS cert on each domain right now
  run      — renew cert and deploy to server via cPanel UAPI  (default)
"

CMD="${1:-run}"

# ── Config ────────────────────────────────────────────────────────────────────
load_config() {
  [[ -f "$CONFIG_FILE" ]] || { echo "ERROR: $CONFIG_FILE not found. Copy config.env.example → config.env." >&2; exit 1; }

  # shellcheck source=config.env
  source "$CONFIG_FILE"

  : "${CERTBOT_EMAIL:?Set CERTBOT_EMAIL in config.env}"
  : "${CERT_NAME:?Set CERT_NAME in config.env}"
  : "${CERTBOT_DOMAINS:?Set CERTBOT_DOMAINS in config.env}"
  : "${CLOUDFLARE_API_TOKEN:?Set CLOUDFLARE_API_TOKEN in config.env}"
  : "${SSH_HOST:?Set SSH_HOST in config.env}"
  : "${CPANEL_DOMAINS:?Set CPANEL_DOMAINS in config.env}"
  : "${VERIFY_DOMAINS:?Set VERIFY_DOMAINS in config.env}"

  CERT_LIVE="/etc/letsencrypt/live/$CERT_NAME"

  # Build certbot -d flags from space-separated CERTBOT_DOMAINS
  CERTBOT_FLAGS=()
  for d in $CERTBOT_DOMAINS; do
    CERTBOT_FLAGS+=(-d "$d")
  done

  # Write a temp cloudflare.ini for certbot and clean it up on exit
  CF_INI="$(mktemp /tmp/cloudflare-XXXXXX.ini)"
  chmod 600 "$CF_INI"
  echo "dns_cloudflare_api_token = $CLOUDFLARE_API_TOKEN" > "$CF_INI"
  trap 'rm -f "$CF_INI"' EXIT
}

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; }

# Install one domain's cert via cPanel UAPI over SSH.
# PEM content is expanded locally and piped as a script — avoids shell-escaping
# multiline strings across an SSH command argument.
cpanel_install_cert() {
  local domain="$1"
  echo "  Installing $domain ..."

  local result
  result="$(ssh "$SSH_HOST" bash << EOF
uapi SSL install_ssl \
  domain='$domain' \
  cert='$(cat "$CERT_LIVE/cert.pem")' \
  key='$(cat "$CERT_LIVE/privkey.pem")' \
  cabundle='$(cat "$CERT_LIVE/chain.pem")'
EOF
)"

  if echo "$result" | grep -q 'status: 1'; then
    ok "$domain — installed"
  else
    fail "$domain — cPanel UAPI error:"
    echo "$result" | grep -E 'errors|message|status' | sed 's/^/    /'
    return 1
  fi
}

# ── check ─────────────────────────────────────────────────────────────────────
cmd_check() {
  load_config
  local pass=true

  echo "--- Config file ---"
  [[ -f "$CONFIG_FILE" ]] && ok "config.env" || { fail "config.env missing"; pass=false; }

  echo ""
  echo "--- Cloudflare token ---"
  if [[ -z "$CLOUDFLARE_API_TOKEN" || "$CLOUDFLARE_API_TOKEN" == "your_token_here" ]]; then
    fail "CLOUDFLARE_API_TOKEN not set in config.env"; pass=false
  else
    local status
    status="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/user/tokens/verify")"
    [[ "$status" == "200" ]] \
      && ok "token valid" \
      || { fail "HTTP $status — check token permissions (needs Zone:DNS:Edit)"; pass=false; }
  fi

  echo ""
  echo "--- SSH ($SSH_HOST) ---"
  local whoami hostname
  read -r whoami hostname < <(ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_HOST" \
    'echo "$(whoami) $(hostname)"' 2>/dev/null) \
    && ok "connected as $whoami on $hostname" \
    || { fail "SSH failed"; pass=false; }

  echo ""
  echo "--- cPanel UAPI ---"
  ssh "$SSH_HOST" 'command -v uapi' &>/dev/null \
    && ok "uapi found" \
    || { fail "uapi not found on remote"; pass=false; }

  echo ""
  if $pass; then
    echo "✓ All checks passed. Next: sudo $(basename "$0") dry-run"
  else
    echo "✗ Fix the issues above before continuing."; exit 1
  fi
}

# ── dry-run ───────────────────────────────────────────────────────────────────
cmd_dry_run() {
  load_config
  echo "==> Certbot dry-run (staging — no real cert issued) ..."
  certbot certonly \
    --dry-run \
    --non-interactive \
    --agree-tos \
    --email "$CERTBOT_EMAIL" \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_INI" \
    --dns-cloudflare-propagation-seconds 30 \
    --cert-name "$CERT_NAME" \
    "${CERTBOT_FLAGS[@]}"
  echo ""
  echo "✓ Dry-run passed. Run the real thing with: sudo $(basename "$0") run"
}

# ── verify ────────────────────────────────────────────────────────────────────
cmd_verify() {
  load_config
  echo "--- Live TLS certificate check ---"
  for domain in $VERIFY_DOMAINS; do
    echo ""
    echo "  $domain:"
    local pem
    pem="$(echo | openssl s_client -connect "$domain:443" -servername "$domain" 2>/dev/null)" || {
      fail "could not connect to $domain:443"; continue
    }
    echo "$pem" | openssl x509 -noout -subject -issuer -dates 2>/dev/null | sed 's/^/    /'

    local sans
    sans="$(echo "$pem" | openssl x509 -noout -text 2>/dev/null \
      | grep -A1 'Subject Alternative Name' | tail -1 | xargs)"
    echo "    SANs: $sans"

    local expiry expiry_epoch now_epoch days_left
    expiry="$(echo "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    expiry_epoch="$(date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null \
      || date -d "$expiry" +%s)"
    now_epoch="$(date +%s)"
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    echo "    Expires in: $days_left days"
  done
}

# ── run ───────────────────────────────────────────────────────────────────────
cmd_run() {
  load_config

  echo "==> Renewing certificate via Cloudflare DNS challenge ..."
  certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "$CERTBOT_EMAIL" \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_INI" \
    --dns-cloudflare-propagation-seconds 30 \
    --cert-name "$CERT_NAME" \
    "${CERTBOT_FLAGS[@]}"

  for f in fullchain.pem privkey.pem cert.pem chain.pem; do
    [[ -f "$CERT_LIVE/$f" ]] || { echo "ERROR: $CERT_LIVE/$f missing after certbot." >&2; exit 1; }
  done

  echo ""
  echo "==> Certificate:"
  openssl x509 -in "$CERT_LIVE/fullchain.pem" -noout -subject -dates

  echo ""
  echo "==> Installing via cPanel UAPI ..."
  for domain in $CPANEL_DOMAINS; do
    cpanel_install_cert "$domain"
  done

  echo ""
  echo "✓ Done. Confirm with: $(basename "$0") verify"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$CMD" in
  check)        cmd_check ;;
  dry-run)      cmd_dry_run ;;
  verify)       cmd_verify ;;
  run)          cmd_run ;;
  -h|--help)    echo "$USAGE" ;;
  *)            echo "Unknown command: $CMD"; echo "$USAGE"; exit 1 ;;
esac
