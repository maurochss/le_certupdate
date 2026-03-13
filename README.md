# le_certupdate

A consolidated Let's Encrypt certificate management script for Linux and OpenBSD servers running NGINX.

## Usage

```
./cert_manager.sh [--debug] [--standalone] [OPTIONS]

  --debug            Enable debug output
  --standalone       Use certbot standalone mode as the default for all domains
                     (overrides DEFAULT_RENEWALL_METHOD; per-domain RENEWALL_METHOD still applies)

Options:
  --new DOMAIN[:METHOD]            Issue a new certificate for DOMAIN.
  --renew all                      Renew all certificates found in /etc/letsencrypt/live/.
  --renew domain DOMAIN[:METHOD]   Renew the certificate for DOMAIN.
  --renew nginx                    Renew certificates for all server_names in NGINX config.
  -h, --help                       Display this help message.
```

Per-domain METHOD suffix (appended with `,` to the domain name):

| Suffix | Method |
|--------|--------|
| `s` or `S` | standalone (e.g. `vpn.example.com,s`) |
| `w` or `W` | webroot (e.g. `www.example.com,w`) |

## Renewal method resolution

For every domain, the auth method is resolved in this priority order:

1. **Inline CLI suffix** — `domain,S` / `domain,W`
2. **`RENEWALL_METHOD` array** — per-domain entry in the env file
3. **`DEFAULT_RENEWALL_METHOD`** — env file default (`W` = webroot, `S` = standalone)
4. **Webroot** — hardcoded fallback if nothing is set

`--renew all` reads folder names from `/etc/letsencrypt/live/` and applies this resolution per domain, so mixed standalone/webroot environments are handled correctly.

> **Note:** Webroot validation requires NGINX to be running to serve the ACME challenge files.

## Configuration

Copy `cert_manager.env.template` to `.cert_manager.env` in the same directory as the script and edit it. The file is auto-discovered by the script.

Key variables:

| Variable | Description |
|---|---|
| `EMAIL` | Let's Encrypt account email (required) |
| `CERTBOT` | Path to certbot binary (auto-detected if unset) |
| `WEBROOT_PATH` | Webroot path for HTTP-01 challenge |
| `NGINX_ENABLED` | Path to nginx sites-enabled directory |
| `LOG_PATH` | Directory for renewal logs |
| `LOG_RETENTION_DAYS` | How many days to keep logs |
| `PF_CONF` / `PF_CONF_TEMP` | OpenBSD pf config paths |
| `DEFAULT_ACTION` | Command run after renewal when no per-domain action matches |
| `ACTIONS` | Array of `"domain,command"` for per-domain post-renewal actions |
| `DEFAULT_RENEWALL_METHOD` | Default certbot auth method: `W` (webroot) or `S` (standalone) |
| `RENEWALL_METHOD` | Array of `"domain,S\|W"` for per-domain certbot auth method |

## Crontab installation

To auto-renew NGINX certs every 12 hours, run as root:

```
crontab -e
```

Add the following line:

```
0 */12 * * * /path/to/cert_manager.sh --renew all >> /var/log/letsencrypt/$(date +\%Y\%m\%d).log 2>&1
```

**Note:** Port 80 is opened only to allow Let's Encrypt validation and is always closed once the renewal process completes (or on script exit/crash).
