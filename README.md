# le_certupdate #

Usage: ./cert_manager.sh [--debug] [OPTIONS]

  --debug            Enable debug

Options:
  --new DOMAIN            Issue a new certificate for the specified DOMAIN.
  --renew all             Renew all certificates.
  --renew domain DOMAIN   Renew the certificate for the specified DOMAIN.
  --renew nginx           Renew certificates for all server_names in NGINX config.
  -h, --help              Display this help message.

TO AUTO RENEW NGINX CERTS BY CRONJOB (Every 12 hours) as root run:


### Crontab installation ###

crontab -e

0 */12 * * * /path/to/cert_manager.sh --renew nginx >> /var/log/letsencrypt/$(date +\%Y\%m\%d).log 2>&1



NOTE: Port 80 is only opened to allow LetsEncrypt queries and it is closed once renewal process is completed.
