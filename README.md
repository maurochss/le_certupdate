# le_certupdate #

Usage: ./cert_manager.sh [--debug] [OPTIONS]<br>

  --debug            Enable debug<br>

Options:<br>
  --new DOMAIN            Issue a new certificate for the specified DOMAIN.<br>
  --renew all             Renew all certificates.<br>
  --renew domain DOMAIN   Renew the certificate for the specified DOMAIN.<br>
  --renew nginx           Renew certificates for all server_names in NGINX config.<br>
  -h, --help              Display this help message.<br>


### Crontab installation ###

TO AUTO RENEW NGINX CERTS BY CRONJOB (Every 12 hours) as root run:

```crontab -e```

And add the bellow line.

0 */12 * * * /path/to/cert_manager.sh --renew nginx >> /var/log/letsencrypt/$(date +\%Y\%m\%d).log 2>&1


**NOTE:** Port 80 is only opened to allow LetsEncrypt queries and it is closed once renewal process is completed.
