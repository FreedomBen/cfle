# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

`cfle` (CloudFlare Let's Encrypt) is a single-purpose container image that renews a Let's Encrypt TLS certificate using the DNS-01 challenge against Cloudflare, then stores the resulting cert in a Kubernetes `Secret`. It is designed to be run as a K8s `CronJob` (the example schedule in `k8s/prod/deploy.yaml` is daily at 16:30).

There is no application code beyond a single bash script — the "app" is `renew.sh` and the Dockerfile that packages it with `certbot`, `python3-certbot-dns-cloudflare`, and `kubectl`.

## High-level architecture

- **`renew.sh`** — the container entrypoint. Full lifecycle:
  1. Validates required env vars (`CLOUDFLARE_EMAIL`, `CLOUDFLARE_API_TOKEN`, `DOMAINS`, `TLS_CERT_SECRET_NAME`).
  2. Resolves target namespace from `K8S_NAMESPACE` or the pod's mounted service-account token.
  3. Checks the existing Secret (if any): if the cert has more than `NUM_DAYS_BEFORE_TO_RENEW` days left (default 30), exits 0 without changes — this makes daily runs safe.
  4. Writes `/root/.secrets/cloudflare.ini`, runs `certbot certonly --dns-cloudflare --preferred-challenges dns-01 --force-renewal`.
  5. Deletes the old Secret and recreates it with the new cert. The Secret contains both lowercase keys (`tls.key`, `tls.crt`, `tls.chain`, `tls.fullchain`) *and* uppercase duplicates (`TLS_PRIVKEY`, `TLS_CERT`, `TLS_CHAIN`, `TLS_FULLCHAIN`) — consumers can depend on either.
  6. Optional Slack notifications via `SLACK_API_TOKEN` and per-severity channel vars.
  7. On failure, `die()` sleeps `DIE_DELAY_SECS` before exiting (defaults to 8 hours in prod config) so the failed pod stays around for log inspection.
- **`TEST_CERT=yes`** switches certbot to Let's Encrypt staging to avoid hitting prod rate limits while iterating. Prod ConfigMap currently has this set — flip to `no` for a real cert.
- **`FORCE_RENEWAL=yes`** bypasses the expiration check.

## Kubernetes layout

- `k8s/{staging,prod}/deploy.yaml` — `CronJob` (named `cfle`) + `ConfigMap` (`cfle-config`). Note: uses `batch/v1beta1`, an API Kubernetes **removed in 1.25** — a ≥1.25 API server rejects these manifests outright, so switch the CronJob to `batch/v1` for any current cluster. The CronJob references `serviceAccountName: cfle-sa`, which does **not** match the SA name defined in `service-account.yaml` (see below) — the example manifests are inconsistent and need reconciling before they will actually run.
- `k8s/{staging,prod}/service-account.yaml` — defines `ServiceAccount/tls-cert-renewal-sa` plus a `Role`/`RoleBinding` (`tls-cert-renewal-role` / `tls-cert-renewal-rb`) granting `get,list,create,delete` on `secrets` and `namespaces`, all in namespace `tls-cert-renewal-ns`.
- `k8s/{staging,prod}/secrets.yaml` and `secrets.yaml.aes` — both files are committed. `.gitignore` has the `secrets.yaml` line commented out, so plaintext is currently *not* ignored — treat the committed `secrets.yaml` files as placeholders, not real secrets, and use the `.aes` files (decrypted out-of-band) for actual values.
- `scripts/change-version.sh` **does** rewrite the `image:` tag in both `k8s/staging/deploy.yaml` and `k8s/prod/deploy.yaml` — its second `sed` loop (the plain `cfle` variant) is live; only the first `cfle-(.*)` variant loop and the `findref`/`LATEST_VERSION=` loop are no-ops (no such lines exist in the tree). The catch: the tag it writes is a fresh `YYYYMMDDHHMMSS` timestamp generated at run time — **not** `RELEASE_VERSION` and **not** the git-SHA tag `build-release.sh` actually built/pushed — so running it can point the manifest at an image tag that was never published. To pin a specific built image, edit the `image:` tag by hand instead.

## Common commands

### Build & push
```
./scripts/build-release.sh   # tags :${RELEASE_VERSION:-$(git rev-parse HEAD)} and :latest
./scripts/push-release.sh    # pushes both tags to docker.io/freedomben/cfle
./scripts/build-dev.sh       # builds freedomben/cfle-dev:latest
./scripts/run-dev.sh         # drops into a bash shell in the dev image
```

### Deploy
```
./scripts/deploy-release.sh --save-all   --env staging --release-ver <ver>
./scripts/deploy-release.sh --diff-all   --env staging --k8s-server <url> --k8s-token <tok>
./scripts/deploy-release.sh --apply-all  --env prod    --k8s-server <url> --k8s-token <tok>
```
`deploy-release.sh` renders manifests with `envsubst` into `manifests-${RELEASE_VERSION}-${ENV}/`, then `kubectl diff` / `apply`. `-l|--save-apply-all` does save+apply in one go. All flags also accept equivalent env vars (`ENV`, `RELEASE_VERSION`, `K8S_SERVER`, `K8S_TOKEN`, `FORCE`, `DEBUG`).

### Bump image version in manifests
```
./scripts/change-version.sh   # rewrites image: tag in BOTH deploy.yaml files to a fresh timestamp
                              # (NOT your built/pushed tag — see Kubernetes layout). Edit by hand to pin a specific image.
```

### Manually trigger a cert renewal on-cluster
```
./scripts/run-prod-onetime.sh   # kubectl create job --from=cronjob/tls-cert-renewal tls-cert-renewal-manual-run-<timestamp>
# Note: the CronJob in deploy.yaml is named `cfle`, not `tls-cert-renewal` — the script's CRONJOB_NAME needs to match whatever was actually deployed.
```

### Inspect the current cert in-cluster
```
./scripts/inspect-certs.sh   # decodes secrets/tls-cert .data.SSL_CERT through openssl x509 -text
# Broken as written: renew.sh writes the key TLS_CERT (and tls.crt), never SSL_CERT, and the script
# hardcodes the secret name `tls-cert`. As-is it returns empty. Use the real key/name instead, e.g.:
#   kubectl get secret <TLS_CERT_SECRET_NAME> -o jsonpath={.data.TLS_CERT} | base64 -d | openssl x509 -noout -text
```

## CI

`.github/workflows/build-test-deploy.yml` runs on push to `master` and currently only builds+pushes the image tagged with `${github.sha}`. The test and deploy jobs are commented out; `scripts/run-ci.sh` is a stub that `exit 0`s before running any tests. There are no tests to run locally.

## Gotchas

- The Dockerfile pins `KUBECTL_VER=v1.25.11` (bumped over time, e.g. 1.24.13 → 1.25.11). Keep it within one minor of the target clusters — note this client is itself old now and pairs with the removed-in-1.25 `batch/v1beta1` manifests above.
- The example manifests have **two name mismatches** worth knowing about before applying them anywhere real: (1) `deploy.yaml` references `serviceAccountName: cfle-sa` while `service-account.yaml` actually creates `tls-cert-renewal-sa`; (2) `run-prod-onetime.sh` targets `cronjob/tls-cert-renewal` while `deploy.yaml` names the CronJob `cfle`. Both need reconciling per-environment.
- `renew.sh` uses `set -e` / `set +e` deliberately around the certbot invocation and secret replacement. When editing, be careful not to collapse those — the script relies on capturing certbot's exit code and continuing past failures to emit Slack notifications.
- The Secret is **deleted and recreated** rather than patched, so anything watching the Secret will see it disappear briefly on renewal.
- `DIE_DELAY_SECS` holds failed pods open for debugging but also means a broken CronJob silently chews up a pod slot for hours. Watch for this when investigating stuck jobs.
- The pre-flight namespace existence check (`kubectl get namespace "${K8S_NAMESPACE}"`) reads `K8S_NAMESPACE` **directly**, while every Secret operation uses the `namespace()` helper that falls back to the pod's own namespace when `K8S_NAMESPACE` is empty. With the example ConfigMap's `K8S_NAMESPACE: ''` these two disagree about which namespace is "the" namespace — set `K8S_NAMESPACE` explicitly to avoid the check failing or checking the wrong namespace.
- Slack failure messages call `cat /etc/podinfo/podname` and `/etc/podinfo/namespace` (Downward API), but **no manifest mounts a `podinfo` volume**, so those substitutions come out empty. Add a `podinfo` `downwardAPI` volume + mount if you want the "check logs with kubectl logs ..." hint to be useful.
- `scripts/deploy-release.sh` and `scripts/run-ci.sh` are generic copies from a Phoenix/Elixir project template: `deploy-release.sh` carries full DB-migration (`migrate.yaml`) and Deployment-rollout machinery, and `run-ci.sh` ends in `mix test`. cfle has **no** `migrate.yaml`, no `Deployment`, and no Elixir — only the deploy.yaml render/diff/apply paths matter; the migration and `mix test` paths are vestigial (`run-ci.sh` also `exit 0`s before ever reaching `mix test`).
