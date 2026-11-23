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
  --renew [all] [--nginx]          Renew every lineage in /etc/letsencrypt/live/ that
                                   expires within the renewal window (--days N, default
                                   RENEW_WITHIN_DAYS=30). With --nginx, lineages not in
                                   use are skipped.
  --renew nginx                    Same as '--renew all --nginx' (default behaviour).
  --renew domain DOMAIN[,METHOD]   Renew the certificate for DOMAIN.
  --find [--nginx] [filters]       List lineages and their Not After date. Renews nothing.
  -h, --help                       Display this help message.

Expiry filters (--find and --renew all|nginx; may be combined):
  --days N | --expired | --before DATE | --after DATE | --match REGEX | --nginx

--find options:
  --format FMT | --keep | -q, --quiet | --refresh
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

`--renew all` reads folder names from `/etc/letsencrypt/live/` and applies this resolution per lineage, so mixed standalone/webroot environments are handled correctly.

> **Note:** Webroot validation requires NGINX to be running to serve the ACME challenge files.

## Which domains get renewed

`--renew all` and `--renew nginx` no longer hand every lineage to certbot. They first
read each lineage's `cert.pem` expiry date locally, and only lineages expiring within
the renewal window (`--days N`, default `RENEW_WITHIN_DAYS=30`) are passed to certbot.
Expiry dates are cached in `$STATE_PATH/expiry.cache`, keyed by the `cert.pem` symlink
target and mtime, so openssl only runs for certificates that changed. When nothing is
due, certbot is never called and port 80 is never opened.

With `--nginx` (or `--renew nginx`, the scheduled default) a due lineage is renewed only
when it is **in use**, i.e. any of:

1. Its certificate is referenced by an `ssl_certificate` directive in `$NGINX_ENABLED`
   (`.../live/<name>/...` or `.../archive/<name>/...`; symlinks are followed).
2. Its name matches a `server_name` in `$NGINX_ENABLED` — this covers vhosts that keep
   their `ssl_certificate` lines in an included snippet outside `$NGINX_ENABLED`.
3. It is declared in the `RENEWALL_METHOD` array.

Due lineages that are not in use are logged as skipped. Source 3 exists because hosts
that terminate TLS without NGINX — VPN endpoints, mail servers, appliances — have no
vhost to be discovered from:

```bash
RENEWALL_METHOD=(
  "vpn.example.com,S"    # standalone; no NGINX vhost exists for this host
)
```

## Finding expiring certificates

`--find` lists lineages with their Not After date and days left (negative = expired);
`[in use]` marks lineages the `--nginx` filter would keep. It renews nothing and does not
touch the firewall.

```
./cert_manager.sh --find --days 30 --nginx
./cert_manager.sh --find --expired
./cert_manager.sh --find --after 2026-10-01 --before 2026-11-01
./cert_manager.sh --find --format %Y-%m-%d --match '^2026-12' --keep
```

`--keep` saves the list to `$STATE_PATH/results/`. `--refresh` ignores the cache.
This replaces the former standalone `find_nginx_expired_certs.sh`.

### Standalone and port 80

`certbot --standalone` binds port 80 itself and fails if something already holds it.
Set `STANDALONE_STOP_SERVICE` to the service that owns the port (typically `nginx`) and
the script stops it via `--pre-hook` and restarts it via `--post-hook` around standalone
renewals only. Left empty, the script warns when it detects an occupied port 80.

## Expired certificate lifecycle

Retired sites leave a lineage behind in `/etc/letsencrypt/` long after their vhost is
gone, and certbot keeps failing to renew them forever. The script tracks these instead:

- Every run checks each lineage's `cert.pem` expiry date (using the expiry cache).
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
| `RENEW_WITHIN_DAYS` | Renewal window in days for `--renew all\|nginx` (default 30; `--days N` overrides) |
| `STANDALONE_STOP_SERVICE` | Service stopped around standalone renewals so certbot can bind port 80 |

## Crontab installation

To auto-renew NGINX certs every 12 hours, run as root:

```
crontab -e
```

Add the following lines. Cron runs jobs with a minimal `PATH` (typically `/usr/bin:/bin`),
which does not include `/usr/local/bin` where `bash`, `certbot` and `nginx` are usually
installed, nor the `sbin` directories holding `pfctl`, `firewall-cmd` and `ip`. Without the
`PATH` line the job fails with `env: bash: No such file or directory`.

```
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 */12 * * * /path/to/cert_manager.sh --renew --nginx >> /var/log/letsencrypt/$(date +\%Y\%m\%d)_cert_renew.log 2>&1
```

**Note:** Port 80 is opened only to allow Let's Encrypt validation and is always closed once the renewal process completes (or on script exit/crash).

The script exits nonzero when any renewal or deletion fails, so cron surfaces a broken
renewal instead of reporting success.
