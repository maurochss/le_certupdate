#!/usr/bin/env bash
# Updates OpenVPN Access Server (openvpn-as) with a renewed Let's Encrypt certificate.
#
# Usage:
#   update_openvpn_cert.sh <domain>
#
# Example .cert_manager.env ACTIONS entry:
#   ACTIONS=(
#     "vpn.example.com,/etc/letsencrypt/scripts/update_openvpn_cert.sh vpn.example.com"
#   )
#######################################################################

DOMAIN="$1"

if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 <domain>"
  exit 1
fi

LIVE_PATH="/etc/letsencrypt/live/$DOMAIN"
SACLI="/usr/local/openvpn_as/scripts/sacli"

if [ ! -d "$LIVE_PATH" ]; then
  echo "Certificate path not found: $LIVE_PATH"
  exit 1
fi

if [ ! -x "$SACLI" ]; then
  echo "sacli not found or not executable: $SACLI"
  exit 1
fi

echo "Updating OpenVPN AS certificate for $DOMAIN..."

"$SACLI" --key "cs.priv_key"   --value_file "$LIVE_PATH/privkey.pem"  ConfigPut
"$SACLI" --key "cs.cert"       --value_file "$LIVE_PATH/cert.pem"     ConfigPut
"$SACLI" --key "cs.ca_bundle"  --value_file "$LIVE_PATH/chain.pem"    ConfigPut

echo "Restarting OpenVPN AS..."
"$SACLI" start

echo "OpenVPN AS certificate updated successfully."
