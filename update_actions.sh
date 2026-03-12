#!/usr/bin/env bash
# Post-renewal actions hook for cert_manager.sh
# Called automatically when one or more certificates are successfully renewed.
#
# Arguments:
#   $1  Path to the renewlist file (one cert name per line)
#   $2  Path to the .cert_manager.env settings file
#
# Configuration (in .cert_manager.env):
#   DEFAULT_ACTION  Command or script to run when no domain-specific action matches.
#   ACTIONS         Bash array of "domain,command_or_script" entries.
#
# Example .cert_manager.env entries:
#   DEFAULT_ACTION="nginx -s reload"
#   ACTIONS=(
#     "example.com,nginx -s reload"
#     "vpn.example.com,systemctl restart openvpn"
#     "vpn.example.com,/etc/letsencrypt/scripts/custom_hook.sh"
#   )
#######################################################################

RENEWLIST_FILE="$1"
SETTINGS_FILE="$2"

if [ -z "$RENEWLIST_FILE" ] || [ ! -f "$RENEWLIST_FILE" ]; then
  echo "Usage: $0 <renewlist-file> <settings-file>"
  exit 1
fi

if [ -f "$SETTINGS_FILE" ]; then
  source "$SETTINGS_FILE"
fi

log() {
  local msg
  msg="[$(date +'%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  [ -n "$LOG_FILE" ] && echo "$msg" >> "$LOG_FILE"
}

# Track executed actions to avoid running the same command twice
# (e.g. nginx reload only once even if multiple certs were renewed)
declare -A EXECUTED_ACTIONS

while IFS= read -r domain; do
  [ -z "$domain" ] && continue
  log "Processing actions for: $domain"

  ACTION=""

  # Check for domain-specific action(s)
  if [ -n "${ACTIONS+x}" ]; then
    for entry in "${ACTIONS[@]}"; do
      entry_domain="${entry%%,*}"
      entry_action="${entry#*,}"
      if [ "$entry_domain" = "$domain" ]; then
        if [ -z "${EXECUTED_ACTIONS[$entry_action]+x}" ]; then
          log "  Running action: $entry_action"
          eval "$entry_action"
          log "  Action exit code: $?"
          EXECUTED_ACTIONS[$entry_action]=1
        else
          log "  Skipping duplicate action: $entry_action"
        fi
        ACTION="matched"
      fi
    done
  fi

  # Fall back to DEFAULT_ACTION if no domain-specific entry matched
  if [ -z "$ACTION" ]; then
    if [ -n "$DEFAULT_ACTION" ]; then
      if [ -z "${EXECUTED_ACTIONS[$DEFAULT_ACTION]+x}" ]; then
        log "  Running default action: $DEFAULT_ACTION"
        eval "$DEFAULT_ACTION"
        log "  Action exit code: $?"
        EXECUTED_ACTIONS[$DEFAULT_ACTION]=1
      else
        log "  Skipping duplicate default action: $DEFAULT_ACTION"
      fi
    else
      log "  No action configured for $domain."
    fi
  fi

done < "$RENEWLIST_FILE"
