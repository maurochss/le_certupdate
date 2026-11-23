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
  --renew [all] [--nginx]          Renew every lineage in /etc/letsencrypt/live/ that
                                   expires within the renewal window (--days N, default
                                   RENEW_WITHIN_DAYS=30). With --nginx, lineages not in
                                   use (see below) are skipped.
  --renew nginx                    Same as '--renew all --nginx' (default behaviour).
  --renew domain DOMAIN[,METHOD]   Renew the certificate for the specified DOMAIN.
  --find [--nginx] [filters]       List lineages in /etc/letsencrypt/live/ and their
                                   Not After date. Nothing is renewed.
  -h, --help                       Display this help message.

Expiry filters (--find and --renew all|nginx; may be combined):
  --days N           Expires within N days from now (includes expired)
  --expired          Already expired
  --before DATE      Not After is before DATE
  --after DATE       Not After is on/after DATE
  --match REGEX      Not After, as displayed (see --format), matches the ERE
  --nginx            Only lineages in use: referenced by ssl_certificate or a
                     server_name in NGINX_ENABLED, or declared in RENEWALL_METHOD
  DATE formats (UTC): YYYY-MM-DD, "YYYY-MM-DD HH:MM[:SS]", "Mon DD YYYY"

--find options:
  --format FMT       strftime format used to display Not After
  --keep             Save the list to \$STATE_PATH/results/
  -q, --quiet        Print only the total
  --refresh          Ignore the Not After cache and re-read every certificate
                     (also accepted by --renew)

Examples:
  ./cert_manager.sh --find --days 30 --nginx
  ./cert_manager.sh --find --expired
  ./cert_manager.sh --renew --nginx --days 20

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

Cron runs with a minimal PATH, so set one first (bash, certbot and nginx usually
live in /usr/local/bin; pfctl, firewall-cmd and ip in the sbin directories):

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 */12 * * * /etc/letsencrypt/scripts/cert_manager.sh --renew --nginx >> /var/log/letsencrypt/\$(date +\%Y\%m\%d)_cert_renew.log 2>&1
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
  cert_expiry "$1" || return 1
  [ "$CERT_EPOCH" -le "${SWEEP_NOW:-$(date -u +%s)}" ]
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
  local SWEEP_NOW
  SWEEP_NOW=$(date -u +%s)
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
### EXPIRY SCAN (formerly find_nginx_expired_certs.sh)
#######################################################################
# Portability helpers (GNU vs BSD date/stat)
if date -u -d @0 +%s >/dev/null 2>&1; then
  GNU_DATE=true
else
  GNU_DATE=false
fi

# Converts a date string (UTC) to epoch seconds.
to_epoch() {
  local s="$1" f
  [ -n "$s" ] || return 1   # GNU date reads "" as today's midnight
  if $GNU_DATE; then
    date -u -d "$s" +%s 2>/dev/null
    return
  fi
  # BSD date leaves unspecified fields at "now", so pad dates to midnight.
  [[ "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && s="$s 00:00:00"
  [[ "$s" =~ ^[A-Za-z]{3}\ +[0-9]{1,2}\ [0-9]{4}$ ]] && s="$s 00:00:00"
  for f in "%b %d %T %Y GMT" "%Y-%m-%d %H:%M:%S" "%Y-%m-%d %H:%M" "%b %d %Y %H:%M:%S"; do
    date -j -u -f "$f" "$s" +%s 2>/dev/null && return
  done
  return 1
}

format_epoch() {
  if $GNU_DATE; then
    date -u -d "@$1" +"$2"
  else
    date -u -r "$1" +"$2"
  fi
}

file_mtime() {
  stat -L -c %Y "$1" 2>/dev/null || stat -L -f %m "$1" 2>/dev/null
}

# Not After cache, one line per lineage: name <TAB> signature <TAB> epoch <TAB> notafter
# The signature is cert.pem's symlink target plus its mtime. A renewal points
# cert.pem at a new archive file, so the entry is always re-read after one.
declare -A C_SIG C_EPOCH C_NOTAFTER
CACHE_LOADED=false
CACHE_DIRTY=false

load_cert_cache() {
  $CACHE_LOADED && return 0
  CACHE_LOADED=true
  if [ "$REFRESH" = true ]; then
    CACHE_DIRTY=true
    return 0
  fi
  [ -r "$CACHE_FILE" ] || return 0
  local name sig epoch notafter
  while IFS=$'\t' read -r name sig epoch notafter; do
    [ -n "$name" ] || continue
    C_SIG[$name]=$sig
    C_EPOCH[$name]=$epoch
    C_NOTAFTER[$name]=$notafter
  done < "$CACHE_FILE"
}

save_cert_cache() {
  [ "$CACHE_DIRTY" = true ] && [ -n "$CACHE_FILE" ] || return 0
  local name tmp="$CACHE_FILE.tmp.$$"
  for name in "${!C_SIG[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "$name" "${C_SIG[$name]}" "${C_EPOCH[$name]}" "${C_NOTAFTER[$name]}"
  done | sort > "$tmp" 2>/dev/null && mv -f "$tmp" "$CACHE_FILE" || rm -f "$tmp"
  CACHE_DIRTY=false
}

# Sets CERT_EPOCH and CERT_NOTAFTER for a lineage; openssl only runs on a
# cache miss. Returns 1 when the certificate can't be read.
cert_expiry() {
  local name="$1" cert="$LIVE_DIR/$1/cert.pem" sig notafter epoch
  [ -r "$cert" ] || return 1
  load_cert_cache
  sig="$(readlink "$cert" 2>/dev/null)@$(file_mtime "$cert")"
  if [ "${C_SIG[$name]}" = "$sig" ] && [ -n "${C_EPOCH[$name]}" ]; then
    CERT_EPOCH=${C_EPOCH[$name]}
    CERT_NOTAFTER=${C_NOTAFTER[$name]}
    return 0
  fi
  notafter=$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | sed 's/^notAfter=//')
  epoch=$(to_epoch "$notafter") || return 1
  [ -n "$epoch" ] || return 1
  C_SIG[$name]=$sig
  C_EPOCH[$name]=$epoch
  C_NOTAFTER[$name]=$notafter
  CACHE_DIRTY=true
  CERT_EPOCH=$epoch
  CERT_NOTAFTER=$notafter
}

# Lineage names referenced by ssl_certificate in the NGINX config
# (.../live/<name>/fullchain.pem or .../archive/<name>/fullchainN.pem).
collect_nginx_cert_lineages() {
  [ -d "$NGINX_ENABLED" ] || return 0
  grep -RhE '^[[:space:]]*ssl_certificate[[:space:]]' "$NGINX_ENABLED"/ 2>/dev/null \
    | sed -E 's/^[[:space:]]*ssl_certificate[[:space:]]+//; s/;.*$//; s/["'\'']//g; s/[[:space:]]+$//' \
    | sed -nE 's#^.*/(live|archive)/([^/]+)/[^/]+$#\2#p'
}

# A lineage is "in use" when NGINX references its certificate file, when it
# is named after an NGINX server_name (covers ssl_certificate lines kept in
# included snippets outside NGINX_ENABLED), or when it is declared in
# RENEWALL_METHOD (VPN endpoints and other hosts with no vhost).
declare -A IN_USE
IN_USE_LOADED=false
lineage_in_use() {
  if ! $IN_USE_LOADED; then
    IN_USE_LOADED=true
    local n
    while IFS= read -r n; do
      [ -n "$n" ] && IN_USE[$n]=1
    done < <(collect_nginx_cert_lineages; collect_nginx_domains 2>/dev/null; collect_env_domains)
  fi
  [ -n "${IN_USE[$1]}" ]
}

# Not After as displayed by --find, and as tested by --match.
shown_notafter() {
  if [ -n "$F_FORMAT" ]; then
    format_epoch "${C_EPOCH[$1]}" "$F_FORMAT"
  else
    printf '%s\n' "${C_NOTAFTER[$1]}"
  fi
}

# Fill SCAN_RESULT with the lineages that pass every active filter:
#   F_UPPER / F_LOWER  Not After must be < F_UPPER and >= F_LOWER (epoch)
#   F_MATCH            displayed Not After must match this ERE
#   NGINX_ONLY=true    lineage must be in use (lineage_in_use)
# Lineages that matched the dates but are not in use land in SCAN_SKIPPED.
scan_certs() {
  SCAN_RESULT=()
  SCAN_SKIPPED=()
  if [ ! -d "$LIVE_DIR" ]; then
    echo "No certificates found at $LIVE_DIR." >&2
    return 1
  fi
  local dir name
  for dir in "$LIVE_DIR"/*/; do
    [ -d "$dir" ] || continue
    name=${dir%/}
    name=${name##*/}
    if ! cert_expiry "$name"; then
      echo "Warning: can't read Not After from $LIVE_DIR/$name/cert.pem" >&2
      continue
    fi
    [ -n "$F_UPPER" ] && [ "$CERT_EPOCH" -ge "$F_UPPER" ] && continue
    [ -n "$F_LOWER" ] && [ "$CERT_EPOCH" -lt "$F_LOWER" ] && continue
    if [ -n "$F_MATCH" ] && ! [[ "$(shown_notafter "$name")" =~ $F_MATCH ]]; then
      continue
    fi
    if $NGINX_ONLY && ! lineage_in_use "$name"; then
      SCAN_SKIPPED+=("$name")
      continue
    fi
    SCAN_RESULT+=("$name")
  done
}

# --find: print the matching lineages with their Not After and days left.
find_certs() {
  scan_certs || return 1
  local name now diff days mark report="" count=0
  now=$(date -u +%s)
  for name in "${SCAN_RESULT[@]}"; do
    count=$((count + 1))
    # Floor division so an already expired cert shows a negative number of days.
    diff=$(( ${C_EPOCH[$name]} - now ))
    days=$(( diff >= 0 ? diff / 86400 : -((-diff + 86399) / 86400) ))
    mark=""
    lineage_in_use "$name" && mark=" [in use]"
    report+=$(printf '%3d - %-50s Not After : %s (%sd)%s' \
      "$count" "$name" "$(shown_notafter "$name")" "$days" "$mark")$'\n'
  done

  $FIND_QUIET || printf '%s' "$report"
  echo "Total: $count"
  if $FIND_KEEP; then
    local result_dir="$CACHE_DIR/results" source=all
    $NGINX_ONLY && source=nginx
    local result_file
    result_file="$result_dir/$(printf '%s' "${source}${FILTER_KEY}" | tr -c 'A-Za-z0-9._-' '_').list"
    mkdir -p "$result_dir" || return 1
    printf '%s' "$report" > "$result_file" || return 1
    $FIND_QUIET || echo "List saved to: $result_file"
  fi
}

# --renew all|nginx: hand certbot only the lineages inside the renewal window.
# Port 80 is opened only when there is something to renew.
renew_due() {
  scan_certs || exit 1
  local name
  for name in "${SCAN_SKIPPED[@]}"; do
    echo "Skipping $name: due, but not used by NGINX or RENEWALL_METHOD."
  done
  if [ ${#SCAN_RESULT[@]} -eq 0 ]; then
    echo "No certificates due for renewal ($FILTER_DESC)."
    return 0
  fi
  echo "${#SCAN_RESULT[@]} certificate(s) due for renewal ($FILTER_DESC): ${SCAN_RESULT[*]}"
  open_port_80
  for name in "${SCAN_RESULT[@]}"; do
    run_certbot_renew "$name"
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
trap 'close_port_80; save_cert_cache' EXIT
trap 'exit 130' INT   # Ctrl+C (SIGINT)
trap 'exit 143' TERM  # kill (SIGTERM)
trap 'exit 129' HUP   # terminal closed (SIGHUP)

RENEW_FAILURES=0
DELETE_FAILURES=0
LIVE_DIR="${LIVE_DIR:-/etc/letsencrypt/live}"
RENEWAL_DIR="${RENEWAL_DIR:-/etc/letsencrypt/renewal}"

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
RENEW_WITHIN_DAYS="${RENEW_WITHIN_DAYS:-30}"
if ! [[ "$RENEW_WITHIN_DAYS" =~ ^[0-9]+$ ]]; then
  echo "Invalid RENEW_WITHIN_DAYS '$RENEW_WITHIN_DAYS'. Use a number of days."
  exit 1
fi
# Not After cache (and --find --keep results). Kept with the state, not the logs.
CACHE_DIR="${CERT_CACHE_DIR:-$STATE_PATH}"
CACHE_FILE="$CACHE_DIR/expiry.cache"

if [ ! -d "$LOG_PATH" ]; then
  mkdir -p "$LOG_PATH"
fi
if [ ! -d "$STATE_PATH" ]; then
  mkdir -p "$STATE_PATH"
fi

die() { echo "Error: $*" >&2; exit 1; }
set_upper() { if [ -z "$F_UPPER" ] || [ "$1" -lt "$F_UPPER" ]; then F_UPPER=$1; fi; }
set_lower() { if [ -z "$F_LOWER" ] || [ "$1" -gt "$F_LOWER" ]; then F_LOWER=$1; fi; }

NOW=$(date -u +%s)
NGINX_ONLY=false
REFRESH=false
FIND_KEEP=false
FIND_QUIET=false
F_UPPER=""      # Not After must be <  F_UPPER (epoch)
F_LOWER=""      # Not After must be >= F_LOWER (epoch)
F_MATCH=""
F_FORMAT=""
FILTER_KEY=""   # filter summary, used to name --keep result files
FILTER_DESC=""  # filter summary, used in log messages

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --standalone) DEFAULT_RENEWALL_METHOD=S ;;  # CLI flag overrides env default
    --debug) set -x ;;
    --nginx) NGINX_ONLY=true ;;
    --expired)
      set_upper "$NOW"
      FILTER_KEY+="_expired"; FILTER_DESC+=" expired"
      ;;
    --days)
      [[ "$2" =~ ^[0-9]+$ ]] || die "--days needs a number of days."
      set_upper $(( NOW + $2 * 86400 ))
      FILTER_KEY+="_days-$2"; FILTER_DESC+=" within $2 days"
      shift
      ;;
    --before|--after)
      [ -n "$2" ] || die "$1 needs a DATE."
      _epoch=$(to_epoch "$2") || die "Can't parse date '$2'. See --help for DATE formats."
      if [ "$1" = "--before" ]; then set_upper "$_epoch"; else set_lower "$_epoch"; fi
      FILTER_KEY+="_${1#--}-$2"; FILTER_DESC+=" ${1#--} $2"
      shift
      ;;
    --match)
      [ -n "$2" ] || die "--match needs a REGEX."
      F_MATCH="$2"
      FILTER_KEY+="_match-$2"; FILTER_DESC+=" matching $2"
      shift
      ;;
    --format)
      [ -n "$2" ] || die "--format needs a strftime format."
      F_FORMAT="$2"
      FILTER_KEY+="_format-$2"
      shift
      ;;
    --refresh) REFRESH=true ;;
    --keep) FIND_KEEP=true ;;
    -q|--quiet) FIND_QUIET=true ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
unset _epoch
set -- "${ARGS[@]}"
# 'nginx' as a subcommand ('--renew nginx', '--find nginx') means --nginx.
if [ "$2" = nginx ]; then
  NGINX_ONLY=true
  set -- "$1" all "${@:3}"
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
  --find)
    [ -z "$2" ] || [ "$2" = all ] || die "Unexpected argument for --find: $2"
    find_certs
    exit $?
    ;;
  --renew)
    # Without an explicit expiry filter, renew what falls inside the window.
    if [ -z "$F_UPPER$F_LOWER$F_MATCH" ]; then
      set_upper $(( NOW + RENEW_WITHIN_DAYS * 86400 ))
      FILTER_DESC=" within $RENEW_WITHIN_DAYS days"
    fi
    $NGINX_ONLY && FILTER_DESC+=", in use"
    FILTER_DESC="${FILTER_DESC# }"
    case "${2:-all}" in
      all)
        renew_due
        ;;
      domain)
        open_port_80
        renew_domain "$3"
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
