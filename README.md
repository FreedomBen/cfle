# cfle — CloudFlare Let's Encrypt

`cfle` is a small container image that renews a Let's Encrypt TLS certificate
using the Cloudflare DNS-01 challenge and stores the resulting cert in a
Kubernetes `Secret`. It is designed to run as a K8s `CronJob` on a frequent
schedule (e.g. daily): if the existing cert still has more than the configured
number of days remaining, `cfle` exits without making any changes, so running
it often is safe and idempotent.

Optionally, `cfle` can post status, warning, and error messages to Slack.

## What it does

1. Reads the existing TLS cert from the target `Secret` (if one exists) and
   checks its expiration date.
2. If the cert still has more than `NUM_DAYS_BEFORE_TO_RENEW` days left
   (default 30), exits cleanly — nothing to do.
3. Otherwise, runs `certbot` with the `dns-cloudflare` plugin to obtain a new
   certificate via the DNS-01 challenge.
4. Deletes the old `Secret` and recreates it containing the new cert, private
   key, chain, and full chain.
5. If a Slack API token is configured, sends a notification to the appropriate
   channel.

## Image

Pre-built images are published to Docker Hub:

```
docker.io/freedomben/cfle:latest
docker.io/freedomben/cfle:<git-sha-or-timestamp>
```

## Configuration

All configuration is passed via environment variables, typically through a
`ConfigMap` (non-sensitive) and `Secret` (sensitive). See the examples in the
[`k8s/`](./k8s) directory.

### Required

| Variable                | Description                                                                                  |
| ----------------------- | -------------------------------------------------------------------------------------------- |
| `CLOUDFLARE_EMAIL`      | Email associated with the Cloudflare account; also used as the Let's Encrypt account email. |
| `CLOUDFLARE_API_TOKEN`  | Cloudflare API token with `Zone:DNS:Edit` permission on the target zone(s).                  |
| `DOMAINS`               | Comma-separated list of domains to include on the cert (e.g. `example.com,*.example.com`).   |
| `TLS_CERT_SECRET_NAME`  | Name of the Kubernetes `Secret` to read from and write the renewed cert into.                |

### Optional

| Variable                   | Default                         | Description                                                                                                                         |
| -------------------------- | ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `K8S_NAMESPACE`            | pod's own namespace             | Namespace for the target `Secret`. Defaults to the service account's mounted namespace.                                             |
| `NUM_DAYS_BEFORE_TO_RENEW` | `30`                            | If the existing cert expires within this many days, renew it; otherwise exit early.                                                 |
| `TEST_CERT`                | unset (real cert)               | When set to a value not starting with `N`/`n`, use the Let's Encrypt **staging** server. Useful during setup to avoid rate limits. |
| `FORCE_RENEWAL`            | unset                           | When set to a value starting with `Y`/`y`, renew the cert even if it is not close to expiring.                                      |
| `DIE_DELAY_SECS`           | unset (exit immediately)        | On failure, sleep this many seconds before exiting. Keeps the failed pod around for `kubectl logs` / `exec` debugging.              |

### Slack integration (all optional)

If `SLACK_API_TOKEN` is unset, all Slack-related variables are ignored and no
messages are sent.

| Variable                | Description                                                                         |
| ----------------------- | ----------------------------------------------------------------------------------- |
| `SLACK_API_TOKEN`       | Slack API token (`xoxp-...` or bot token) with `chat:write` permission.             |
| `SLACK_CHANNEL_SUCCESS` | Channel for successful renewal notifications.                                        |
| `SLACK_CHANNEL_ERROR`   | Channel for failure notifications.                                                   |
| `SLACK_CHANNEL_WARNING` | Channel for warnings.                                                                |
| `SLACK_CHANNEL_INFO`    | Channel for informational messages (e.g. "cert not yet due for renewal").            |
| `SLACK_CHANNEL_DEBUG`   | Channel for verbose debug output. Setting this effectively enables debug messaging.  |
| `SLACK_USERNAME`        | Display name for the bot. Defaults to `CFLE - Lets Encrypt Certificate Renewer`.     |
| `SLACK_ICON_EMOJI`      | Emoji icon for the bot (e.g. `:lock:`). Defaults to `:scroll:`.                      |

## Secret contents

After a successful run, the target `Secret` contains eight keys — four
lowercase (dotted) and four uppercase duplicates, so consumers can read
whichever convention they use:

| Key             | Uppercase alias  | Contents                                   |
| --------------- | ---------------- | ------------------------------------------ |
| `tls.key`       | `TLS_PRIVKEY`    | Private key (`privkey.pem`)                |
| `tls.crt`       | `TLS_CERT`       | Leaf certificate (`cert.pem`)              |
| `tls.chain`     | `TLS_CHAIN`      | Intermediate chain (`chain.pem`)           |
| `tls.fullchain` | `TLS_FULLCHAIN`  | Leaf + intermediates (`fullchain.pem`)     |

## Kubernetes example

See [`k8s/prod/deploy.yaml`](./k8s/prod/deploy.yaml) and
[`k8s/staging/deploy.yaml`](./k8s/staging/deploy.yaml) for working `CronJob` +
`ConfigMap` manifests, and [`k8s/prod/service-account.yaml`](./k8s/prod/service-account.yaml)
for the RBAC the pod needs (get/create/delete on `secrets` in the target
namespace).

To run the CronJob immediately without waiting for the schedule:

```sh
./scripts/run-prod-onetime.sh
```

which wraps:

```sh
kubectl create job --from=cronjob/tls-cert-renewal tls-cert-renewal-manual-run-$(date '+%Y-%m-%d-%H-%M-%S')
```

## Building locally

```sh
# Build and tag with the current git SHA plus :latest
./scripts/build-release.sh

# Or build a dev image for local experimentation
./scripts/build-dev.sh
./scripts/run-dev.sh   # drops into a bash shell inside the image
```

Override the tag by exporting `RELEASE_VERSION` before running the build script.

## Inspecting the current certificate

```sh
./scripts/inspect-certs.sh
```

decodes the cert stored in the `tls-cert` Secret and pipes it through
`openssl x509 -noout -text`.

## Base image

The container is based on AlmaLinux 8 (chosen over RHEL UBI because some
required packages — notably `python3-certbot-dns-cloudflare` — are not in the
UBI repos). If you have a RHEL subscription, swapping the base image to RHEL
should be a drop-in replacement for a fully supported configuration.

## License

See [LICENSE](./LICENSE).
