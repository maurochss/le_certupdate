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
  --renew all                      Renew every lineage in /etc/letsencrypt/live/.
  --renew domain DOMAIN[,METHOD]   Renew the certificate for the specified DOMAIN.
  --renew nginx                    Renew every NGINX server_name PLUS every domain
                                   declared in RENEWALL_METHOD (default behaviour).
  -h, --help                       Display this help message.

Per-domain METHOD (appended with ',' to the domain name):
  s or S    standalone  (e.g. vpn.example.com,s)
  w or W    webroot     (e.g. www.example.com,w  — same as omitting the suffix)

Domains that have no NGINX vhost (VPN endpoints, mail hosts, appliances) are
picked up from the RENEWALL_METHOD array in the settings file, so they renew
alongside the NGINX ones without needing a vhost to be discovered.

Expired lineages are counted once per calendar day. After MAX_INVALID_DAYS
distinct days they are removed with 'certbot delete' and recorded, together
with their DNS status, in the deletion history file.

TO AUTO RENEW CERTS BY CRONJOB (Every 12 hours) as root run:

crontab -e
0 */12 * * * /etc/letsencrypt/scripts/cert_manager.sh --renew nginx >> /var/log/letsencrypt/\$(date +\%Y\%m\%d)_cert_renew.log 2>&1
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
# True when a local process already holds TCP port 80.
# certbot --standalone binds :80 itself, so an occupied port means failure.
port_80_in_use() {
  if command -v ss &>/dev/null; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'
  elif command -v netstat &>/dev/null; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'
  else
    return 1
  fi
}
#######################################################################
# True when an entry is a well-formed "domain,METHOD" pair.
# Guards against settings-file damage - a stray line swallowed into the
# RENEWALL_METHOD array must not be mistaken for a domain.
_valid_method_entry() {
  local entry="$1"
  case "$entry" in
    *,*) ;;
    *) return 1 ;;
  esac
  case "${entry##*,}" in
    [sS]|standalone|[wW]|webroot) return 0 ;;
    *) return 1 ;;
  esac
}

# Warn about unusable RENEWALL_METHOD entries once, at startup, instead of
# aborting the whole run the first time the renewal loop trips over one.
validate_settings() {
  if ! _valid_method_entry "x,${DEFAULT_RENEWALL_METHOD:-W}"; then
    echo "Invalid DEFAULT_RENEWALL_METHOD '${DEFAULT_RENEWALL_METHOD}'. Use 'S' or 'W'."
    exit 1
  fi
  local entry
  for entry in "${RENEWALL_METHOD[@]}"; do
    [ -n "$entry" ] || continue
    _valid_method_entry "$entry" && continue
    echo "Warning: ignoring malformed RENEWALL_METHOD entry: '$entry'"
    echo "         Expected \"domain,S\" or \"domain,W\"."
    if [[ "$entry" == *=* ]]; then
      echo "         That looks like a setting swallowed into the array."
      echo "         Check for a missing ')' in $SETTINGS_FILE."
    fi
  done
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

  # Check per-domain env array. Malformed entries are skipped: they were
  # already reported by validate_settings and must not abort the run.
  local entry
  for entry in "${RENEWALL_METHOD[@]}"; do
    [ -n "$entry" ] || continue
    _valid_method_entry "$entry" || continue
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
# True when certbot actually knows about this lineage.
lineage_exists() {
  [ -f "$RENEWAL_DIR/$1.conf" ] || [ -d "$LIVE_DIR/$1" ]
}

# Report whether the domain still has a DNS record.
# Used to tell the admin whether a DNS entry needs removing after a deletion.
dns_status() {
  local domain="$1" answer=""
  if command -v dig &>/dev/null; then
    answer=$(dig +short "$domain" 2>/dev/null)
  elif command -v host &>/dev/null; then
    host "$domain" &>/dev/null && answer="present"
  else
    getent hosts "$domain" &>/dev/null && answer="present"
  fi
  if [ -n "$answer" ]; then echo "present"; else echo "absent"; fi
}

# True when the lineage's certificate is already past its notAfter date.
cert_is_invalid() {
  local cert="$LIVE_DIR/$1/cert.pem"
  [ -f "$cert" ] || return 1
  ! openssl x509 -checkend 0 -noout -in "$cert" &>/dev/null
}

# Drop a domain from the invalid tracker (it renewed, or it was deleted).
clear_invalid_cert() {
  local domain="$1"
  [ -f "$INVALID_STATE_FILE" ] || return 0
  grep -v "^${domain}," "$INVALID_STATE_FILE" > "${INVALID_STATE_FILE}.tmp" 2>/dev/null
  mv "${INVALID_STATE_FILE}.tmp" "$INVALID_STATE_FILE"
}

# Remove a lineage that has been expired for MAX_INVALID_DAYS days and
# append it to the deletion history, including whether DNS still resolves.
delete_invalid_cert() {
  local domain="$1" days="$2" first_seen="$3"
  local dns note
  dns=$(dns_status "$domain")
  if [ "$dns" = "present" ]; then
    note="DNS record still resolves - remove it from the DNS server"
  else
    note="DNS record already absent - no administrative action needed"
  fi

  echo "  Deleting $domain after $days invalid day(s) since $first_seen."
  if $CERTBOT delete --cert-name "$domain" --non-interactive; then
    if [ ! -s "$DELETED_HISTORY_FILE" ]; then
      echo "# deleted_on,domain,first_invalid,days_invalid,dns_record,admin_note" > "$DELETED_HISTORY_FILE"
    fi
    printf '%s,%s,%s,%s,%s,%s\n' \
      "$(date +%F)" "$domain" "$first_seen" "$days" "$dns" "$note" >> "$DELETED_HISTORY_FILE"
    echo "  Deleted. $note"
    clear_invalid_cert "$domain"
  else
    echo "  ERROR: 'certbot delete --cert-name $domain' failed. Will retry next run."
    DELETE_FAILURES=$((DELETE_FAILURES + 1))
  fi
}

# Count one calendar day of invalidity for a domain. The schedule may fire
# several times a day, so the counter only advances when the date changes.
record_invalid_cert() {
  local domain="$1"
  local today first_seen last_seen days found=0
  local s_domain s_first s_last s_days
  today=$(date +%F)

  : > "${INVALID_STATE_FILE}.tmp"
  if [ -f "$INVALID_STATE_FILE" ]; then
    while IFS=, read -r s_domain s_first s_last s_days; do
      [ -z "$s_domain" ] && continue
      if [ "$s_domain" = "$domain" ]; then
        found=1
        first_seen="$s_first"
        last_seen="$today"
        if [ "$s_last" = "$today" ]; then
          days="$s_days"
        else
          days=$(( s_days + 1 ))
        fi
        printf '%s,%s,%s,%s\n' "$domain" "$first_seen" "$last_seen" "$days" >> "${INVALID_STATE_FILE}.tmp"
      else
        printf '%s,%s,%s,%s\n' "$s_domain" "$s_first" "$s_last" "$s_days" >> "${INVALID_STATE_FILE}.tmp"
      fi
    done < "$INVALID_STATE_FILE"
  fi

  if [ "$found" -eq 0 ]; then
    first_seen="$today"
    days=1
    printf '%s,%s,%s,%s\n' "$domain" "$first_seen" "$today" "$days" >> "${INVALID_STATE_FILE}.tmp"
  fi
  mv "${INVALID_STATE_FILE}.tmp" "$INVALID_STATE_FILE"

  echo "  INVALID: $domain is expired - day $days of $MAX_INVALID_DAYS (first seen $first_seen)."
  if [ "$days" -ge "$MAX_INVALID_DAYS" ]; then
    if [ "${AUTO_DELETE_INVALID:-true}" = "true" ]; then
      delete_invalid_cert "$domain" "$days" "$first_seen"
    else
      echo "  AUTO_DELETE_INVALID is disabled. Delete manually: $CERTBOT delete --cert-name $domain"
    fi
  fi
}

# Walk every lineage and update the invalid tracker. Run AFTER renewals so a
# certificate that just renewed is no longer counted as invalid.
sweep_invalid_certs() {
  [ -d "$LIVE_DIR" ] || return 0
  mkdir -p "$STATE_PATH"
  local domain_dir domain
  echo "Checking for expired certificates..."
  for domain_dir in "$LIVE_DIR"/*/; do
    [ -d "$domain_dir" ] || continue
    domain=$(basename "$domain_dir")
    if cert_is_invalid "$domain"; then
      record_invalid_cert "$domain"
    else
      clear_invalid_cert "$domain"
    fi
  done
}
#######################################################################
# Renew one domain. Resolves the auth method, skips unknown lineages, and
# guards the standalone path against an occupied port 80.
run_certbot_renew() {
  parse_domain_method "$1"
  local domain="$PARSED_DOMAIN"
  local auth=("${PARSED_AUTH[@]}")
  local hooks=("${CERTBOT_HOOKS[@]}")

  if ! lineage_exists "$domain"; then
    echo "Skipping $domain: certbot has no lineage for it (nothing to renew)."
    return 0
  fi

  if [ "${auth[0]}" = "--standalone" ] && port_80_in_use; then
    if [ -n "$STANDALONE_STOP_SERVICE" ]; then
      echo "Port 80 is busy; stopping $STANDALONE_STOP_SERVICE around the standalone renewal."
      hooks+=(--pre-hook "systemctl stop $STANDALONE_STOP_SERVICE"
              --post-hook "systemctl start $STANDALONE_STOP_SERVICE")
    else
      echo "WARNING: port 80 is already in use. Standalone renewal of $domain will likely"
      echo "         fail to bind. Set STANDALONE_STOP_SERVICE in $SETTINGS_FILE."
    fi
  fi

  echo "Renewing certificate for $domain (method: ${auth[0]})..."
  if $CERTBOT renew --cert-name "$domain" "${auth[@]}" "${hooks[@]}" --agree-tos -m "$EMAIL"; then
    return 0
  fi
  echo "ERROR: renewal failed for $domain."
  RENEW_FAILURES=$((RENEW_FAILURES + 1))
  return 1
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
  if [ ! -d "$LIVE_DIR" ]; then
    echo "No certificates found at $LIVE_DIR."
    exit 1
  fi

  local domain_dir domain
  for domain_dir in "$LIVE_DIR"/*/; do
    [ -d "$domain_dir" ] || continue
    domain=$(basename "$domain_dir")
    run_certbot_renew "$domain"
  done
}
#######################################################################
# Renew a specific certificate
renew_domain() {
  if [ -z "$1" ]; then
    echo "Please specify a domain name to renew its certificate."
    exit 1
  fi
  run_certbot_renew "$1"
}
#######################################################################
# Every server_name declared in the NGINX config.
# sites-enabled holds symlinks, so grep needs -R (not -r) to follow them.
collect_nginx_domains() {
  if [ ! -d "$NGINX_ENABLED" ]; then
    echo "Notice: $NGINX_ENABLED not found; using RENEWALL_METHOD entries only." >&2
    return 0
  fi
  grep -RhE '^[[:space:]]*server_name[[:space:]]+' "$NGINX_ENABLED"/ 2>/dev/null \
    | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/;.*$//' \
    | tr -s '[:space:]' '\n' \
    | grep -vE '^(_|localhost)?$' \
    | grep -v '^\*'
}

# Every domain declared in RENEWALL_METHOD. These are the hosts that have no
# NGINX vhost to be discovered from - VPN endpoints, appliances, and the like.
collect_env_domains() {
  local entry
  for entry in "${RENEWALL_METHOD[@]}"; do
    [ -n "$entry" ] || continue
    _valid_method_entry "$entry" || continue
    echo "${entry%%,*}"
  done
}

# Default renewal pass: NGINX server_names plus env-declared domains.
renew_nginx() {
  local targets domain
  targets=$( { collect_nginx_domains; collect_env_domains; } | awk 'NF' | sort -u )

  if [ -z "$targets" ]; then
    echo "No renewal targets found in $NGINX_ENABLED or RENEWALL_METHOD."
    return 1
  fi

  while IFS= read -r domain; do
    run_certbot_renew "$domain"
  done <<< "$targets"
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

RENEW_FAILURES=0
DELETE_FAILURES=0
LIVE_DIR="/etc/letsencrypt/live"
RENEWAL_DIR="/etc/letsencrypt/renewal"

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
    exit 1
  elif [ -z "$CERTBOT" ]
  then
    CERTBOT=$(which certbot)
    if [ -z "$CERTBOT" ]
    then
      echo "Missing certbot."
      exit 1
    fi
  fi
fi

validate_settings

# Expired-certificate tracking. This must NOT live under LOG_PATH: the log
# cleanup below deletes files older than LOG_RETENTION_DAYS, which would wipe
# a counter that has to survive MAX_INVALID_DAYS.
STATE_PATH="${STATE_PATH:-/var/lib/cert_manager}"
INVALID_STATE_FILE="$STATE_PATH/invalid_certs.state"
DELETED_HISTORY_FILE="$STATE_PATH/deleted_certs.history"
MAX_INVALID_DAYS="${MAX_INVALID_DAYS:-30}"

if [ ! -d "$LOG_PATH" ]; then
  mkdir -p "$LOG_PATH"
fi
if [ ! -d "$STATE_PATH" ]; then
  mkdir -p "$STATE_PATH"
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
    # Accept both 'nginx' and '--nginx' spellings.
    case "${2#--}" in
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
    sweep_invalid_certs
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
echo "Deleting logs older than ${LOG_RETENTION_DAYS:-10} days..."
find "$LOG_PATH" -type f -mtime "+${LOG_RETENTION_DAYS:-10}" -exec rm -fv {} \;

echo "Done. Logs can be found at $LOG_FILE"

# Surface failures to cron instead of always reporting success.
if [ "$RENEW_FAILURES" -gt 0 ] || [ "$DELETE_FAILURES" -gt 0 ]; then
  echo "Completed with $RENEW_FAILURES renewal failure(s) and $DELETE_FAILURES deletion failure(s)."
  exit 1
fi
