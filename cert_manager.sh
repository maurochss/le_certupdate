#!/usr/bin/env bash
# Written by: MChSS
# Consolidated LetsEncrypt Management Script
#######################################################################
### VARIABLES
#######################################################################
# 
# SEE .cert_manager.env (dot cert_manager.env)
#
#######################################################################
### FUNCTIONS
#######################################################################
# Print help
print_help() {
  cat <<EOF
Usage: ./cert_manager.sh [--debug] [--standalone] [OPTIONS]

  --debug            Enable debug
  --standalone       Use certbot standalone mode instead of webroot (global default)

Options:
  --new DOMAIN[,METHOD]            Issue a new certificate for the specified DOMAIN.
  --renew all                      Renew all certificates.
  --renew domain DOMAIN[,METHOD]   Renew the certificate for the specified DOMAIN.
  --renew nginx                    Renew certificates for all server_names in NGINX config.
  -h, --help                       Display this help message.

Per-domain METHOD (appended with ',' to the domain name):
  s or S    standalone  (e.g. vpn.example.com,s)
  w or W    webroot     (e.g. www.example.com,w  — same as omitting the suffix)

TO AUTO RENEW NGINX CERTS BY CRONJOB (Every 12 hours) as root run:

crontab -e
0 */12 * * * /etc/letsencrypt/scripts/cert_manager.sh --renew --nginx >> /var/log/letsencrypt/20251217.log 2>&1
EOF
}
#######################################################################
# Get the network interface that has the default gateway
get_default_iface() {
  case "$OS" in
    OpenBSD)
      if command -v route &>/dev/null; then
        route -n show | awk '/^default/ {print $NF; exit}'
      else
        netstat -rn | awk '/^default/ {print $NF; exit}'
      fi
      ;;
    Linux)
      ip route show default | awk 'NR==1 {print $5}'
      ;;
  esac
}
#######################################################################
# Detect the OS and open port 80
open_port_80() {
  local iface
  iface=$(get_default_iface)
  if [ -z "$iface" ]; then
    echo "Could not determine default gateway interface. Aborting."
    exit 1
  fi
  PORT_80_OPENED=true
  echo "Opening port 80 on interface $iface..."
  case "$OS" in
    OpenBSD)
      cp "$PF_CONF" "$PF_CONF_TEMP"
      echo "pass in on $iface proto tcp from any to any port 80" | tee -a "$PF_CONF_TEMP"
      pfctl -f "$PF_CONF_TEMP"
      ;;
    Linux)
      if command -v firewall-cmd &>/dev/null; then
        local zone
        zone=$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null || echo "public")
        firewall-cmd --zone="$zone" --add-port=80/tcp --timeout=5m
      elif command -v ufw &>/dev/null; then
        ufw allow in on "$iface" to any port 80 proto tcp
      elif command -v iptables &>/dev/null; then
        iptables -A INPUT -i "$iface" -p tcp --dport 80 -j ACCEPT
      fi
      ;;
    *)
      echo "Unsupported OS for firewall operations."
      exit 1
      ;;
  esac
}
#######################################################################
# Close port 80
close_port_80() {
  $PORT_80_OPENED || return 0
  local iface
  iface=$(get_default_iface)
  if [ -z "$iface" ]; then
    echo "Warning: could not determine default gateway interface. Port 80 may still be open."
    return 1
  fi
  echo "Closing port 80 on interface $iface..."
  case "$OS" in
    OpenBSD)
      pfctl -f "$PF_CONF"
      ;;
    Linux)
      if command -v firewall-cmd &>/dev/null; then
        local zone
        zone=$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null || echo "public")
        firewall-cmd --zone="$zone" --remove-port=80/tcp
      elif command -v ufw &>/dev/null; then
        ufw delete allow in on "$iface" to any port 80 proto tcp
      elif command -v iptables &>/dev/null; then
        iptables -D INPUT -i "$iface" -p tcp --dport 80 -j ACCEPT
      fi
      ;;
    *)
      echo "Unsupported OS for firewall operations."
      exit 1
      ;;
  esac
}
#######################################################################
# Resolve a method letter (S/W) to PARSED_AUTH array
_apply_method() {
  case "${1,,}" in
    s|standalone)
      PARSED_AUTH=(--standalone)
      ;;
    w|webroot)
      PARSED_AUTH=(--webroot --webroot-path "$WEBROOT_PATH")
      ;;
    *)
      echo "Unknown renewal method '$1'. Use 'S' for standalone or 'W' for webroot."
      exit 1
      ;;
  esac
}

# Parse "domain[,method]" — sets PARSED_DOMAIN and PARSED_AUTH.
# Resolution order:
#   1. Inline CLI suffix  (domain,S / domain,W)
#   2. RENEWALL_METHOD array from env  ("domain,S")
#   3. DEFAULT_RENEWALL_METHOD from env
#   4. Webroot (hardcoded fallback)
parse_domain_method() {
  local arg="$1"
  if [[ "$arg" == *,* ]]; then
    PARSED_DOMAIN="${arg%,*}"
    _apply_method "${arg##*,}"
    return
  fi

  PARSED_DOMAIN="$arg"

  # Check per-domain env array
  local entry
  for entry in "${RENEWALL_METHOD[@]}"; do
    local entry_domain="${entry%%,*}"
    local entry_method="${entry##*,}"
    if [ "$entry_domain" = "$PARSED_DOMAIN" ]; then
      _apply_method "$entry_method"
      return
    fi
  done

  # Fall back to DEFAULT_RENEWALL_METHOD, then webroot
  _apply_method "${DEFAULT_RENEWALL_METHOD:-W}"
}
#######################################################################
# Issue a new certificate
issue_certificate() {
  parse_domain_method "$1"
  local domain="$PARSED_DOMAIN"
  local auth=("${PARSED_AUTH[@]}")

  if [ -z "$domain" ]; then
    echo "Please specify a domain name for certificate issuance."
    exit 1
  fi

  if [ -z "$(dig "$domain" +short)" ]; then
    echo "No DNS record found for $domain. Verify the domain is registered."
    exit 1
  fi

  $CERTBOT -v certonly -d "$domain" "${auth[@]}" "${CERTBOT_HOOKS[@]}" --agree-tos -m "$EMAIL"
}
#######################################################################
# Renew all certificates
renew_all() {
  local live_dir="/etc/letsencrypt/live"
  if [ ! -d "$live_dir" ]; then
    echo "No certificates found at $live_dir."
    exit 1
  fi

  for domain_dir in "$live_dir"/*/; do
    local domain
    domain=$(basename "$domain_dir")
    parse_domain_method "$domain"
    echo "Renewing certificate for $domain (method: ${PARSED_AUTH[0]})..."
    $CERTBOT renew --cert-name "$domain" "${PARSED_AUTH[@]}" "${CERTBOT_HOOKS[@]}" --agree-tos -m "$EMAIL"
  done
}
#######################################################################
# Renew a specific certificate
renew_domain() {
  parse_domain_method "$1"
  local domain="$PARSED_DOMAIN"
  local auth=("${PARSED_AUTH[@]}")

  if [ -z "$domain" ]; then
    echo "Please specify a domain name to renew its certificate."
    exit 1
  fi

  $CERTBOT renew --cert-name "$domain" "${auth[@]}" "${CERTBOT_HOOKS[@]}" --agree-tos -m "$EMAIL"
}
#######################################################################
# Renew certificates for NGINX server_names
renew_nginx() {
  if [ ! -d "$NGINX_ENABLED" ]; then
    echo "NGINX sites-enabled directory not found."
    exit 1
  fi

  local domains=$(grep -h "server_name" "$NGINX_ENABLED"/* | awk '{print $2}' | tr -d ';')
  for domain in $domains; do
    parse_domain_method "$domain"
    echo "Renewing certificate for $domain (method: ${PARSED_AUTH[0]})..."
    $CERTBOT renew --cert-name "$domain" "${PARSED_AUTH[@]}" "${CERTBOT_HOOKS[@]}" --agree-tos -m "$EMAIL"
  done
}
#######################################################################
### MAIN
#######################################################################
# Handle --help early, before traps or env loading.
for _arg in "$@"; do
  case "$_arg" in
    -h|--help)
      print_help
      if [ "$(id -u)" -ne 0 ]; then
        echo ""
        echo "Note: This script requires root/sudo to manage firewall rules and certificates."
      fi
      exit 0
      ;;
  esac
done
unset _arg

# Set up traps to ensure port 80 is closed on exit or crash.
# Signal traps call exit so the EXIT trap fires once and handles cleanup.
PORT_80_OPENED=false
trap 'close_port_80' EXIT
trap 'exit 130' INT   # Ctrl+C (SIGINT)
trap 'exit 143' TERM  # kill (SIGTERM)
trap 'exit 129' HUP   # terminal closed (SIGHUP)

SETTINGS_FILE="$(dirname "$0")/.$(basename "$0" .sh).env"

if [ ! -f "$SETTINGS_FILE" ]
then
  echo "Missing $SETTINGS_FILE"
  exit 1
else
  source "$SETTINGS_FILE"
  if [ -z "$EMAIL" ]
  then
    echo "Missing e-mail address. Add the bellow variable in $SETTINGS_FILE"
    echo "remenber to replce myemail@mydomain.com with your e-mail address."
    exit
  elif [ -z $CERTBOT ]
  then
    CERTBOT=$(which certbot)
    if [ -z "$CERTBOT" ] 
    then
      echo "Missing certbot."
      exit 1
    fi
  fi
fi

if [ ! -d "$LOG_PATH" ]; then
  mkdir -p "$LOG_PATH"
fi

ARGS=()
for arg in "$@"; do
  case "$arg" in
    --standalone) DEFAULT_RENEWALL_METHOD=S ;;  # CLI flag overrides env default
    --debug) set -x ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]}"

RENEWLIST_FILE="${LOG_PATH}${DATE}-renewlist.log"
CERTBOT_HOOKS=(--deploy-hook "basename \$RENEWED_LINEAGE >> $RENEWLIST_FILE")

if [ $# -eq 0 ]; then
  print_help
  exit 0
fi

case "$1" in
  --new)
    open_port_80
    issue_certificate "$2"
    ;;
  --renew)
    open_port_80
    case "$2" in
      all)
        renew_all
        ;;
      domain)
        renew_domain "$3"
        ;;
      nginx)
        renew_nginx
        ;;
      *)
        echo "Invalid option for --renew."
        print_help
        exit 1
        ;;
    esac
    ;;
  -h|--help)
    print_help
    ;;
  *)
    echo "Invalid option."
    print_help
    exit 1
    ;;
esac
# Run post-renewal actions if any certificates were renewed
ACTIONS_SCRIPT="$(dirname "$0")/update_actions.sh"
if [ -f "$RENEWLIST_FILE" ] && [ "$(wc -l < "$RENEWLIST_FILE")" -gt 0 ]; then
  echo "Certificates renewed. Running post-renewal actions..."
  if [ -f "$ACTIONS_SCRIPT" ]; then
    "$ACTIONS_SCRIPT" "$RENEWLIST_FILE" "$SETTINGS_FILE"
  else
    echo "Warning: $ACTIONS_SCRIPT not found. Skipping post-renewal actions."
  fi
else
  echo "No certs updated. No actions required."
fi
# Clean up old logs
echo "Deleting logs older than 10 days..."
find "$LOG_PATH" -type f -mtime "+""$LOG_RETENTION_DAYS" -exec rm -fv {} \;

echo "Done. Logs can be found at $LOG_FILE"
