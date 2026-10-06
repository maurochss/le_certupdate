#!/usr/bin/env bash
#######################################################################
# List Let's Encrypt certificates and their "Not After" date, optionally
# filtered by expiry. Every cert's Not After is cached (keyed by path +
# file mtime) so repeated runs only call openssl for certs that changed.
# With --keep, the list matching the source/filter combination is saved to a file.
#######################################################################

NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/sites-enabled}"
LIVE_DIR="${LIVE_DIR:-/etc/letsencrypt/live}"
CACHE_DIR="${CERT_CACHE_DIR:-/var/tmp/le_certupdate}"

print_help() {
  cat <<EOF
Usage: $(basename "$0") [--nginx|--all] [filters] [options]

Source (default: --nginx):
  --nginx             Certs referenced by ssl_certificate in $NGINX_ENABLED
  --all               Every cert in $LIVE_DIR/*/fullchain.pem

Filters on "Not After" (may be combined; a cert must match all of them):
  --expired           Already expired
  --days N            Expires within N days from now (includes expired)
  --before DATE       Not After is before DATE
  --after DATE        Not After is on/after DATE
  --match REGEX       Not After, as displayed (see --format), matches the
                      extended regex. e.g. --match Oct
                      or --format %Y-%m-%d --match '^2026-10-0[1-5]'

  DATE formats (UTC): YYYY-MM-DD, "YYYY-MM-DD HH:MM[:SS]", "Mon DD YYYY"

Options:
  --format FMT        strftime format used to display Not After
                      (default: openssl's, e.g. "Oct  3 21:28:00 2026 GMT")
  --refresh           Ignore the cache and re-read every certificate
  --keep              Save the resulting list to $CACHE_DIR/results/
  --cache-dir DIR     Cache/result directory (default: $CACHE_DIR,
                      or env CERT_CACHE_DIR)
  -q, --quiet         Print only the total
  -h, --help          Show this help

Examples:
  $(basename "$0") --days 30
  $(basename "$0") --all --before 2026-11-01 --after 2026-10-01
  $(basename "$0") --match Oct
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

#######################################################################
### Portability helpers (GNU vs BSD date/stat)
#######################################################################
if date -u -d @0 +%s >/dev/null 2>&1; then
  GNU_DATE=true
else
  GNU_DATE=false
fi

# Converts a date string (UTC) to epoch seconds.
to_epoch() {
  local s="$1" f
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

#######################################################################
### Argument parsing
#######################################################################
SOURCE=nginx
NOW=$(date -u +%s)
LOWER=""        # Not After must be >= LOWER
UPPER=""        # Not After must be <  UPPER
MATCH=""
FORMAT=""
REFRESH=false
QUIET=false
KEEP=false
FILTER_KEY=""   # Human readable description of the filters, used to name the result file

set_upper() { if [ -z "$UPPER" ] || [ "$1" -lt "$UPPER" ]; then UPPER=$1; fi; }
set_lower() { if [ -z "$LOWER" ] || [ "$1" -gt "$LOWER" ]; then LOWER=$1; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --nginx) SOURCE=nginx ;;
    --all) SOURCE=all ;;
    --expired)
      set_upper "$NOW"
      FILTER_KEY+="_expired"
      ;;
    --days)
      [[ "$2" =~ ^[0-9]+$ ]] || die "--days needs a number of days."
      set_upper $(( NOW + $2 * 86400 ))
      FILTER_KEY+="_days-$2"
      shift
      ;;
    --before|--after)
      [ -n "$2" ] || die "$1 needs a DATE."
      epoch=$(to_epoch "$2") || die "Can't parse date '$2'. See --help for DATE formats."
      if [ "$1" = "--before" ]; then set_upper "$epoch"; else set_lower "$epoch"; fi
      FILTER_KEY+="_${1#--}-$2"
      shift
      ;;
    --match)
      [ -n "$2" ] || die "--match needs a REGEX."
      MATCH="$2"
      FILTER_KEY+="_match-$2"
      shift
      ;;
    --format)
      [ -n "$2" ] || die "--format needs a strftime format."
      FORMAT="$2"
      FILTER_KEY+="_format-$2"
      shift
      ;;
    --refresh) REFRESH=true ;;
    --keep) KEEP=true ;;
    --cache-dir)
      [ -n "$2" ] || die "--cache-dir needs a directory."
      CACHE_DIR="$2"
      shift
      ;;
    -q|--quiet) QUIET=true ;;
    -h|--help) print_help; exit 0 ;;
    *) echo "Invalid option: $1" >&2; print_help >&2; exit 1 ;;
  esac
  shift
done

CACHE_FILE="$CACHE_DIR/notafter.cache"
RESULT_DIR="$CACHE_DIR/results"
mkdir -p "$CACHE_DIR" 2>/dev/null || die "Can't create $CACHE_DIR. Use --cache-dir or CERT_CACHE_DIR."
if $KEEP; then
  mkdir -p "$RESULT_DIR" 2>/dev/null || die "Can't create $RESULT_DIR. Use --cache-dir or CERT_CACHE_DIR."
fi
RESULT_FILE="$RESULT_DIR/$(printf '%s' "${SOURCE}${FILTER_KEY}" | tr -c 'A-Za-z0-9._-' '_').list"

#######################################################################
### Collect certificate paths
#######################################################################
list_nginx_certs() {
  [ -d "$NGINX_ENABLED" ] || die "$NGINX_ENABLED not found."
  # ssl_certificate only (not ssl_certificate_key); commented lines have $1 == "#".
  awk '$1 == "ssl_certificate" { sub(/;.*/, "", $2); print $2 }' "$NGINX_ENABLED"/* 2>/dev/null | sort -u
}

list_all_certs() {
  [ -d "$LIVE_DIR" ] || die "$LIVE_DIR not found."
  local f
  for f in "$LIVE_DIR"/*/fullchain.pem; do
    [ -e "$f" ] && echo "$f"
  done
}

if [ "$SOURCE" = nginx ]; then
  CERTS=$(list_nginx_certs)
else
  CERTS=$(list_all_certs)
fi

#######################################################################
### Load cache: path <TAB> mtime <TAB> epoch <TAB> notafter
#######################################################################
declare -A C_MTIME C_EPOCH C_NOTAFTER
if ! $REFRESH && [ -r "$CACHE_FILE" ]; then
  while IFS=$'\t' read -r path mtime epoch notafter; do
    C_MTIME[$path]=$mtime
    C_EPOCH[$path]=$epoch
    C_NOTAFTER[$path]=$notafter
  done < "$CACHE_FILE"
fi
CACHE_DIRTY=$REFRESH

#######################################################################
### Evaluate and print
#######################################################################
TMP_RESULT=$(mktemp "$CACHE_DIR/.result.XXXXXX") || die "Can't write to $CACHE_DIR."
trap 'rm -f "$TMP_RESULT" "$CACHE_FILE.tmp.$$"' EXIT

count=0
while IFS= read -r cert; do
  [ -n "$cert" ] || continue
  if [ ! -r "$cert" ]; then
    echo "Warning: can't read $cert" >&2
    continue
  fi

  mtime=$(file_mtime "$cert")
  if [ -n "${C_MTIME[$cert]}" ] && [ "${C_MTIME[$cert]}" = "$mtime" ]; then
    epoch=${C_EPOCH[$cert]}
    notafter=${C_NOTAFTER[$cert]}
  else
    notafter=$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | sed 's/^notAfter=//')
    epoch=$(to_epoch "$notafter")
    if [ -z "$notafter" ] || [ -z "$epoch" ]; then
      echo "Warning: can't read Not After from $cert" >&2
      continue
    fi
    C_MTIME[$cert]=$mtime
    C_EPOCH[$cert]=$epoch
    C_NOTAFTER[$cert]=$notafter
    CACHE_DIRTY=true
  fi

  [ -n "$UPPER" ] && [ "$epoch" -ge "$UPPER" ] && continue
  [ -n "$LOWER" ] && [ "$epoch" -lt "$LOWER" ] && continue

  if [ -n "$FORMAT" ]; then
    shown=$(format_epoch "$epoch" "$FORMAT")
  else
    shown=$notafter
  fi
  if [ -n "$MATCH" ] && ! [[ "$shown" =~ $MATCH ]]; then
    continue
  fi

  # Floor division so an already expired cert shows a negative number of days.
  diff=$(( epoch - NOW ))
  days=$(( diff >= 0 ? diff / 86400 : -((-diff + 86399) / 86400) ))
  ((count++))
  printf '%3d - %-60s Not After : %s (%sd)\n' "$count" "$cert" "$shown" "$days" >> "$TMP_RESULT"
done <<< "$CERTS"

if $CACHE_DIRTY; then
  for path in "${!C_MTIME[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "$path" "${C_MTIME[$path]}" "${C_EPOCH[$path]}" "${C_NOTAFTER[$path]}"
  done | sort > "$CACHE_FILE.tmp.$$" && mv -f "$CACHE_FILE.tmp.$$" "$CACHE_FILE"
fi

$QUIET || cat "$TMP_RESULT"
echo "Total: $count"
if $KEEP; then
  mv -f "$TMP_RESULT" "$RESULT_FILE"
  $QUIET || echo "List saved to: $RESULT_FILE"
fi
