#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
CF_INI=""

USAGE="Usage: $(basename "$0") [check | dry-run | verify | ssl-status | run]

  check       — test config, local dependencies, Cloudflare token, SSH, and cPanel UAPI
  dry-run     — full certbot dry run against staging; no real cert issued
  verify      — check the public/edge TLS cert on each configured verify domain
  ssl-status  — show public/edge TLS status plus cPanel origin SSL inventory
  run         — issue/renew cert and deploy to server via cPanel UAPI; default
"

CMD="${1:-run}"

# ── Helpers ───────────────────────────────────────────────────────────────────

ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; }
warn() { echo "  ! $*"; }

cleanup() {
  [[ -n "${CF_INI:-}" && -f "$CF_INI" ]] && rm -f "$CF_INI"
}

# ── Config ────────────────────────────────────────────────────────────────────

load_config() {
  [[ -f "$CONFIG_FILE" ]] || {
    echo "ERROR: $CONFIG_FILE not found. Copy config.env.example → config.env." >&2
    exit 1
  }

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

  CERTBOT_FLAGS=()
  for domain in $CERTBOT_DOMAINS; do
    CERTBOT_FLAGS+=(-d "$domain")
  done

  CF_INI="$(mktemp /tmp/cloudflare-XXXXXX.ini)"
  chmod 600 "$CF_INI"
  printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" > "$CF_INI"

  trap cleanup EXIT
}

# ── Shared certificate helpers ────────────────────────────────────────────────

parse_cert_expiry_epoch() {
  local expiry="$1"

  date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null \
    || date -d "$expiry" +%s 2>/dev/null
}

print_public_tls_status() {
  local heading="${1:---- Public edge TLS status ---}"

  echo "$heading"
  echo "    Note: if a domain is proxied through Cloudflare, this shows the Cloudflare edge certificate."
  echo "          The cPanel/UAPI section shows the origin-side certificate inventory."

  local domain pem cert_pem subject issuer expiry expiry_epoch now_epoch days_left sans status_label

  for domain in $VERIFY_DOMAINS; do
    echo ""
    echo "  $domain:"

    if ! pem="$(echo | openssl s_client -connect "$domain:443" -servername "$domain" -showcerts 2>/dev/null)"; then
      fail "could not connect to $domain:443"
      continue
    fi

    cert_pem="$(
      echo "$pem" | awk '
        /-----BEGIN CERTIFICATE-----/ { in_cert=1 }
        in_cert { print }
        /-----END CERTIFICATE-----/ { exit }
      '
    )"

    if [[ -z "$cert_pem" ]]; then
      fail "could not extract leaf certificate"
      continue
    fi

    subject="$(echo "$cert_pem" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')"
    issuer="$(echo "$cert_pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
    expiry="$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    sans="$(
      echo "$cert_pem" | openssl x509 -noout -text 2>/dev/null \
        | grep -A1 'Subject Alternative Name' \
        | tail -1 \
        | xargs
    )"

    if [[ -z "$expiry" ]]; then
      fail "could not read certificate expiry"
      continue
    fi

    expiry_epoch="$(parse_cert_expiry_epoch "$expiry" || true)"

    if [[ -z "$expiry_epoch" ]]; then
      fail "could not parse expiry date: $expiry"
      continue
    fi

    now_epoch="$(date +%s)"
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if (( days_left < 0 )); then
      status_label="✗ EXPIRED"
    elif (( days_left < 15 )); then
      status_label="! EXPIRING SOON"
    else
      status_label="✓ VALID"
    fi

    echo "    Status:     $status_label"
    echo "    Days left:  $days_left"
    echo "    Expires:    $expiry"
    echo "    Subject:    $subject"
    echo "    Issuer:     $issuer"
    echo "    SANs:       ${sans:-unknown}"
  done
}

# ── cPanel UAPI install ───────────────────────────────────────────────────────

cpanel_install_cert() {
  local domain="$1"
  echo "  Installing $domain ..."

  local cert_pem key_pem chain_pem result

  cert_pem="$(cat "$CERT_LIVE/cert.pem")"
  key_pem="$(cat "$CERT_LIVE/privkey.pem")"
  chain_pem="$(cat "$CERT_LIVE/chain.pem")"

  result="$(
    ssh "$SSH_HOST" DOMAIN="$domain" bash <<EOF
set -euo pipefail

tmpdir="\$(mktemp -d)"
trap 'rm -rf "\$tmpdir"' EXIT

cat > "\$tmpdir/cert.pem" <<'CERT_EOF'
$cert_pem
CERT_EOF

cat > "\$tmpdir/privkey.pem" <<'KEY_EOF'
$key_pem
KEY_EOF

cat > "\$tmpdir/chain.pem" <<'CHAIN_EOF'
$chain_pem
CHAIN_EOF

uapi --output=json SSL install_ssl \\
  domain="\$DOMAIN" \\
  cert="\$(cat "\$tmpdir/cert.pem")" \\
  key="\$(cat "\$tmpdir/privkey.pem")" \\
  cabundle="\$(cat "\$tmpdir/chain.pem")"
EOF
  )"

  python3 - "$domain" "$result" <<'PY'
import json
import sys

domain = sys.argv[1]
raw = sys.argv[2].strip()

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    print(f"  ✗ {domain} — could not parse UAPI install response")
    print(raw)
    sys.exit(1)

result = payload.get("result", payload)

if result.get("status") == 1:
    print(f"  ✓ {domain} — installed")
    sys.exit(0)

print(f"  ✗ {domain} — cPanel UAPI error")

for key in ("errors", "messages", "warnings", "metadata"):
    value = result.get(key)
    if value:
        print(f"    {key}: {value}")

sys.exit(1)
PY
}

# ── check ─────────────────────────────────────────────────────────────────────

cmd_check() {
  load_config
  local pass=true

  echo "--- Config file ---"
  [[ -f "$CONFIG_FILE" ]] && ok "config.env found" || { fail "config.env missing"; pass=false; }

  echo ""
  echo "--- Local dependencies ---"
  for cmd in certbot curl ssh openssl python3; do
    command -v "$cmd" >/dev/null \
      && ok "$cmd found" \
      || { fail "$cmd not found"; pass=false; }
  done

  if command -v certbot >/dev/null; then
    certbot plugins 2>/dev/null | grep -q 'dns-cloudflare' \
      && ok "certbot dns-cloudflare plugin found" \
      || { fail "certbot dns-cloudflare plugin missing"; pass=false; }
  fi

  echo ""
  echo "--- Config values ---"
  [[ "$CLOUDFLARE_API_TOKEN" != "your_token_here" ]] \
    && ok "Cloudflare token value is set" \
    || { fail "Cloudflare token is still placeholder"; pass=false; }

  [[ -n "$CERTBOT_DOMAINS" ]] && ok "CERTBOT_DOMAINS set: $CERTBOT_DOMAINS" || { fail "CERTBOT_DOMAINS empty"; pass=false; }
  [[ -n "$CPANEL_DOMAINS" ]] && ok "CPANEL_DOMAINS set: $CPANEL_DOMAINS" || { fail "CPANEL_DOMAINS empty"; pass=false; }
  [[ -n "$VERIFY_DOMAINS" ]] && ok "VERIFY_DOMAINS set: $VERIFY_DOMAINS" || { fail "VERIFY_DOMAINS empty"; pass=false; }

  echo ""
  echo "--- Cloudflare token ---"
  local cf_status
  cf_status="$(
    curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/user/tokens/verify"
  )"

  [[ "$cf_status" == "200" ]] \
    && ok "token valid" \
    || { fail "HTTP $cf_status — check token permissions; Certbot DNS challenge needs DNS edit access"; pass=false; }

  echo ""
  echo "--- SSH ($SSH_HOST) ---"
  local remote_identity

  if remote_identity="$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_HOST" 'printf "%s %s\n" "$(whoami)" "$(hostname)"' 2>/dev/null)"; then
    ok "connected as $remote_identity"
  else
    fail "SSH failed"
    pass=false
  fi

  echo ""
  echo "--- cPanel UAPI ---"
  ssh "$SSH_HOST" 'command -v uapi' &>/dev/null \
    && ok "uapi found" \
    || { fail "uapi not found on remote"; pass=false; }

  if ssh "$SSH_HOST" 'uapi --output=json SSL list_certs >/dev/null 2>&1'; then
    ok "SSL list_certs callable"
  else
    fail "SSL list_certs failed"
    pass=false
  fi

  echo ""
  if $pass; then
    echo "✓ All checks passed. Next: sudo $(basename "$0") dry-run"
  else
    echo "✗ Fix the issues above before continuing."
    exit 1
  fi
}

# ── dry-run ───────────────────────────────────────────────────────────────────

cmd_dry_run() {
  load_config

  echo "==> Certbot dry-run using Cloudflare DNS challenge ..."
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
  print_public_tls_status "--- Public/edge TLS certificate check ---"
}

# ── ssl-status ────────────────────────────────────────────────────────────────

cmd_ssl_status() {
  load_config

  print_public_tls_status "--- Public edge TLS status ---"

  echo ""
  echo "--- cPanel origin SSL inventory ---"

  if ! ssh "$SSH_HOST" 'command -v uapi' &>/dev/null; then
    fail "uapi not found on remote"
    return 1
  fi

  echo ""
  echo "  Installed SSL hosts:"

  local installed_hosts_json
  installed_hosts_json="$(ssh "$SSH_HOST" 'uapi --output=json SSL installed_hosts 2>/dev/null' || true)"

  python3 - "$installed_hosts_json" <<'PY'
import json
import sys

raw = sys.argv[1].strip()

if not raw:
    print("    No output from UAPI installed_hosts.")
    sys.exit(0)

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    print("    Could not parse installed_hosts JSON output.")
    print(raw)
    sys.exit(0)

result = payload.get("result", payload)

if result.get("status") != 1:
    print("    UAPI installed_hosts returned an error.")
    for key in ("errors", "messages", "warnings", "metadata"):
        value = result.get(key)
        if value:
            print(f"    {key}: {value}")
    sys.exit(0)

data = result.get("data", [])

if not data:
    print("    No installed SSL hosts returned.")
    sys.exit(0)

for item in data:
    domain = (
        item.get("domain")
        or item.get("servername")
        or item.get("host")
        or item.get("vhost_name")
        or "unknown-domain"
    )
    print(f"    - {domain}")
PY

  echo ""
  echo "  Stored SSL certificates:"

  local certs_json
  certs_json="$(ssh "$SSH_HOST" 'uapi --output=json SSL list_certs 2>/dev/null' || true)"

  python3 - "$certs_json" <<'PY'
import json
import sys
from datetime import datetime, timezone

raw = sys.argv[1].strip()

if not raw:
    print("    No output from UAPI list_certs.")
    sys.exit(0)

try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    print("    Could not parse list_certs JSON output.")
    print(raw)
    sys.exit(0)

result = payload.get("result", payload)

if result.get("status") != 1:
    print("    UAPI list_certs returned an error.")
    for key in ("errors", "messages", "warnings", "metadata"):
        value = result.get(key)
        if value:
            print(f"    {key}: {value}")
    sys.exit(0)

data = result.get("data", [])

if not data:
    print("    No stored SSL certificates returned.")
    sys.exit(0)

def fmt_epoch(value):
    if value in (None, "", "unknown"):
        return "unknown", None

    try:
        epoch = int(value)
        dt = datetime.fromtimestamp(epoch, tz=timezone.utc)
        days_left = (dt - datetime.now(timezone.utc)).days
        return dt.strftime("%Y-%m-%d %H:%M:%S UTC"), days_left
    except (TypeError, ValueError, OSError):
        return str(value), None

for cert in data:
    common_name = cert.get("subject.commonName", "unknown CN")
    issuer_org = cert.get("issuer.organizationName", "")
    issuer_cn = cert.get("issuer.commonName", "")
    issuer = " ".join(part for part in (issuer_org, issuer_cn) if part) or "unknown issuer"

    not_after, days_left = fmt_epoch(cert.get("not_after"))
    not_before, _ = fmt_epoch(cert.get("not_before"))

    domains = cert.get("domains", [])
    friendly_name = cert.get("friendly_name", "")

    validation_type = cert.get("validation_type", "unknown")
    key_algorithm = cert.get("key_algorithm", "unknown")
    signature_algorithm = cert.get("signature_algorithm", "unknown")

    if days_left is None:
        status = "UNKNOWN"
    elif days_left < 0:
        status = "EXPIRED"
    elif days_left < 15:
        status = "EXPIRING SOON"
    else:
        status = "VALID"

    print(f"    - {common_name}")
    print(f"      status:      {status}")
    if days_left is not None:
        print(f"      days left:   {days_left}")
    print(f"      issuer:      {issuer}")
    print(f"      valid from:  {not_before}")
    print(f"      expires:     {not_after}")
    print(f"      validation:  {validation_type}")
    print(f"      key:         {key_algorithm}")
    print(f"      signature:   {signature_algorithm}")

    if domains:
        print("      domains:")
        for domain in domains:
            print(f"        - {domain}")
    elif friendly_name:
        print(f"      domains:     {friendly_name}")
PY
}

# ── VPS deploy ───────────────────────────────────────────────────────────────

vps_deploy_cert() {
  [[ -n "${VPS_HOST:-}" ]] || { warn "VPS_HOST not set — skipping VPS deploy"; return 0; }

  echo "==> Deploying cert to VPS ($VPS_HOST) ..."

  scp "$CERT_LIVE/fullchain.pem" "$CERT_LIVE/privkey.pem" "$VPS_HOST:/tmp/"
  ssh "$VPS_HOST" "
    sudo mv /tmp/fullchain.pem /tmp/privkey.pem ${VPS_CERT_DIR}/
    sudo chmod 644 ${VPS_CERT_DIR}/fullchain.pem
    sudo chmod 600 ${VPS_CERT_DIR}/privkey.pem
    sudo docker exec caddy caddy reload --config /etc/caddy/Caddyfile
  "

  ok "cert deployed and Caddy reloaded"
}

# ── run ───────────────────────────────────────────────────────────────────────

cmd_run() {
  load_config

  echo "==> Issuing/renewing certificate via Cloudflare DNS challenge ..."
  certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "$CERTBOT_EMAIL" \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_INI" \
    --dns-cloudflare-propagation-seconds 30 \
    --cert-name "$CERT_NAME" \
    "${CERTBOT_FLAGS[@]}"

  echo ""
  echo "==> Checking local certificate files ..."
  for file in fullchain.pem privkey.pem cert.pem chain.pem; do
    [[ -s "$CERT_LIVE/$file" ]] || {
      echo "ERROR: $CERT_LIVE/$file missing or empty after certbot." >&2
      exit 1
    }
    ok "$file present"
  done

  echo ""
  echo "==> Certificate:"
  openssl x509 -in "$CERT_LIVE/fullchain.pem" -noout -subject -issuer -dates

  echo ""
  echo "==> Installing via cPanel UAPI ..."
  for domain in $CPANEL_DOMAINS; do
    cpanel_install_cert "$domain"
  done

  echo ""
  echo "✓ Install complete."

  echo ""
  vps_deploy_cert

  echo ""
  echo "==> Verifying SSL status ..."
  cmd_ssl_status
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$CMD" in
  check)        cmd_check ;;
  dry-run)      cmd_dry_run ;;
  verify)       cmd_verify ;;
  ssl-status)   cmd_ssl_status ;;
  run)          cmd_run ;;
  -h|--help)    echo "$USAGE" ;;
  *)            echo "Unknown command: $CMD"; echo "$USAGE"; exit 1 ;;
esac
