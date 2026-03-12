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
  --standalone       Use certbot standalone mode instead of webroot (for servers without a web server)

Options:
  --new DOMAIN            Issue a new certificate for the specified DOMAIN.
  --renew all             Renew all certificates.
  --renew domain DOMAIN   Renew the certificate for the specified DOMAIN.
  --renew nginx           Renew certificates for all server_names in NGINX config.
  -h, --help              Display this help message.

TO AUTO RENEW NGINX CERTS BY CRONJOB (Every 12 hours) as root run:

crontab -e
0 */12 * * * /etc/letsencrypt/scripts/cert_manager.sh --renew --nginx >> /var/log/letsencrypt/20251217.log 2>&1
EOF
}
#######################################################################
# Detect the OS and open port 80
open_port_80() {
  echo "Opening port 80..."
  case "$OS" in
    OpenBSD)
      cp "$PF_CONF" "$PF_CONF_TEMP"
      echo "pass in on em0 proto tcp from any to any port 80" | tee -a $PF_CONF_TEMP
      pfctl -f "$PF_CONF_TEMP"
      ;;
    Linux)
      if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --add-port=80/tcp --timeout 5m
      elif command -v ufw &>/dev/null; then
        ufw allow 80/tcp
      elif command -v iptables &>/dev/null; then
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
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
  echo "Closing port 80..."
  case "$OS" in
    OpenBSD)
      pfctl -f "$PF_CONF"
      ;;
    Linux)
      if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --remove-port=80/tcp
      elif command -v ufw &>/dev/null; then
        ufw delete allow 80/tcp
      elif command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport 80 -j ACCEPT
      fi
      ;;
    *)
      echo "Unsupported OS for firewall operations."
      exit 1
      ;;
  esac
}
#######################################################################
# Issue a new certificate
issue_certificate() {
  local domain=$1
  if [ -z "$domain" ]; then
    echo "Please specify a domain name for certificate issuance."
    exit 1
  fi

  if [ -z "$(dig "$domain" +short)" ]; then
    echo "No DNS record found for $domain. Verify the domain is registered."
    exit 1
  fi

  $CERTBOT -v certonly -d "$domain" "${CERTBOT_AUTH[@]}" "${CERTBOT_HOOKS[@]}" --agree-tos -m "$EMAIL"
}
#######################################################################
# Renew all certificates
renew_all() {
  $CERTBOT renew "${CERTBOT_AUTH[@]}" "${CERTBOT_HOOKS[@]}" --agree-tos -m "$EMAIL"
}
#######################################################################
# Renew a specific certificate
renew_domain() {
  local domain=$1
  if [ -z "$domain" ]; then
    echo "Please specify a domain name to renew its certificate."
    exit 1
  fi

  $CERTBOT renew --cert-name "$domain" "${CERTBOT_AUTH[@]}" "${CERTBOT_HOOKS[@]}" --agree-tos -m "$EMAIL"
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
    echo "Renewing certificate for $domain..."
    $CERTBOT renew --cert-name "$domain" "${CERTBOT_AUTH[@]}" "${CERTBOT_HOOKS[@]}" --agree-tos -m "$EMAIL"
  done
}
#######################################################################
### MAIN
#######################################################################
# Set up traps to ensure port 80 is closed on exit or crash.
# Signal traps call exit so the EXIT trap fires once and handles cleanup.
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

STANDALONE=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --standalone) STANDALONE=true ;;
    --debug) set -x ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]}"

if $STANDALONE; then
  CERTBOT_AUTH=(--standalone)
else
  CERTBOT_AUTH=(--webroot --webroot-path "$WEBROOT_PATH")
fi

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
