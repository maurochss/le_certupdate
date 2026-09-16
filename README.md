# le_certupdate

A consolidated Let's Encrypt certificate management script for Linux and OpenBSD servers running NGINX.

## Usage

```
./cert_manager.sh [--debug] [--standalone] [OPTIONS]

  --debug            Enable debug output
  --standalone       Use certbot standalone mode as the default for all domains
                     (overrides DEFAULT_RENEWALL_METHOD; per-domain RENEWALL_METHOD still applies)

Options:
  --new DOMAIN[,METHOD]            Issue a new certificate for DOMAIN.
  --renew all                      Renew every lineage found in /etc/letsencrypt/live/.
  --renew domain DOMAIN[,METHOD]   Renew the certificate for DOMAIN.
  --renew nginx                    Renew every NGINX server_name PLUS every domain
                                   declared in RENEWALL_METHOD. (default behaviour)
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

## Which domains get renewed

`--renew nginx` is the scheduled default. It renews the **union** of two sources:

1. Every `server_name` found in `$NGINX_ENABLED` (symlinks are followed; multi-name
   directives such as `server_name a.com b.com;` yield both names; `_`, `localhost`
   and wildcards are ignored).
2. Every domain declared in the `RENEWALL_METHOD` array.

Source 2 exists because hosts that terminate TLS without NGINX — VPN endpoints, mail
servers, appliances — have no vhost to be discovered from. Declaring them in
`RENEWALL_METHOD` is what makes them visible to the renewal pass:

```bash
RENEWALL_METHOD=(
  "vpn.example.com,S"    # standalone; no NGINX vhost exists for this host
)
```

A missing `$NGINX_ENABLED` directory is a notice, not a fatal error — the env-declared
domains still renew. A `server_name` with no corresponding certbot lineage is skipped
with a message rather than handed to certbot.

### Standalone and port 80

`certbot --standalone` binds port 80 itself and fails if something already holds it.
Set `STANDALONE_STOP_SERVICE` to the service that owns the port (typically `nginx`) and
the script stops it via `--pre-hook` and restarts it via `--post-hook` around standalone
renewals only. Left empty, the script warns when it detects an occupied port 80.

## Expired certificate lifecycle

Retired sites leave a lineage behind in `/etc/letsencrypt/` long after their vhost is
gone, and certbot keeps failing to renew them forever. The script tracks these instead:

- Every run checks each lineage's `cert.pem` with `openssl x509 -checkend 0`.
- An expired lineage is counted **once per calendar day**. The schedule may fire several
  times a day; the counter still advances only once.
- After `MAX_INVALID_DAYS` distinct days (default 30) the lineage is removed with
  `certbot delete --cert-name` and appended to `$STATE_PATH/deleted_certs.history`.
- If a certificate renews successfully, its counter is discarded.

The history file records whether DNS still resolved at deletion time, so a stale record
can be cleaned off the DNS server:

```
# deleted_on,domain,first_invalid,days_invalid,dns_record,admin_note
2026-09-16,speed2.example.com,2026-08-17,30,present,DNS record still resolves - remove it from the DNS server
```

Set `AUTO_DELETE_INVALID="false"` to keep the counting and reporting but never delete.

> **`STATE_PATH` must not live inside `LOG_PATH`.** The log cleanup deletes files older
> than `LOG_RETENTION_DAYS` (default 10) and would wipe a 30-day counter mid-count.

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
| `RENEWALL_METHOD` | Array of `"domain,S\|W"` — per-domain auth method, and the registry of domains with no NGINX vhost |
| `STATE_PATH` | Directory for the expiry counter and deletion history (must be outside `LOG_PATH`) |
| `MAX_INVALID_DAYS` | Days a certificate may stay expired before its lineage is deleted |
| `AUTO_DELETE_INVALID` | `true` to delete expired lineages automatically, `false` to only report |
| `STANDALONE_STOP_SERVICE` | Service stopped around standalone renewals so certbot can bind port 80 |

## Crontab installation

To auto-renew NGINX certs every 12 hours, run as root:

```
crontab -e
```

Add the following line:

```
0 */12 * * * /path/to/cert_manager.sh --renew nginx >> /var/log/letsencrypt/$(date +\%Y\%m\%d)_cert_renew.log 2>&1
```

**Note:** Port 80 is opened only to allow Let's Encrypt validation and is always closed once the renewal process completes (or on script exit/crash).

The script exits nonzero when any renewal or deletion fails, so cron surfaces a broken
renewal instead of reporting success.
