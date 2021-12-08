#!/usr/bin/env bash

# Example Env vars:
#CLOUDFLARE_EMAIL='ben@example.com'
#CLOUDFLARE_API_TOKEN='awekjltaSAGKLHG'
#DOMAINS='example.com,*.example.com'
# TLS_CERT_SECRET_NAME

# Slack integration
#SLACK_API_TOKEN='xoxp-...'
#SLACK_CHANNEL_DEBUG='#debug'  # If set, debug mode will be enabled
#SLACK_CHANNEL_INFO='#info'
#SLACK_CHANNEL_WARNING='#warning'
#SLACK_CHANNEL_ERROR='#main'
#SLACK_CHANNEL_SUCCESS='#main'
#SLACK_USERNAME='Some Username'
#SLACK_ICON_EMOJI=':scroll:'  # or :lock: or something


NUM_SECS_IN_MONTH=2592000  # month == 30 days, 60 * 60 * 24 * 30

num_secs_until_expire ()
{
  if [ -n "${NUM_DAYS_BEFORE_TO_RENEW}" ]; then
    echo "$(( $NUM_DAYS_BEFORE_TO_RENEW * 24 * 60 * 60 ))"
  else
    echo "${NUM_SECS_IN_MONTH}"
  fi
}

die ()
{
  echo "[DIE] - $(date): ${1}"
  slack_error "${1}"
  exit 1
}

log ()
{
  echo "[LOG] - $(date): ${1}"
}

slack_icon_emoji ()
{
  if [ -n "${SLACK_ICON_EMOJI}" ]; then
    echo "${SLACK_ICON_EMOJI}"
  else
    echo ":scroll:"
  fi
}

slack_username ()
{
  if [ -n "${SLACK_USERNAME}" ]; then
    echo "${SLACK_USERNAME}"
  else
    echo "CFLE - Lets Encrypt Certificate Renewer"
  fi
}

send_slack_message ()
{
  local username="Deploy of ${GITHUB_REPOSITORY} to ${ENV}"
  if [ -n "${SLACK_API_TOKEN}" ]; then
    log "SLACK_API_TOKEN is set.  sending slack message to channel ${1}"
    curl \
      --data "token=${SLACK_API_TOKEN}&channel=#${1}&text=${2}&username=$(slack_username)&icon_emoji=$(slack_icon_emoji)" \
      'https://slack.com/api/chat.postMessage'
    echo # add a new-line to the output so it's easier to read the logs
  else
    log "SLACK_API_TOKEN is not present.  Message not sent to slack channel '${1}' message: '${2}'"
  fi
}

slack_success ()
{
  send_slack_message "${SLACK_CHANNEL_SUCCESS}" ":white_check_mark:  ${1}"
}

slack_error ()
{
  send_slack_message "${SLACK_CHANNEL_ERROR}" ":x:  ${1}"
}

slack_warning ()
{
  send_slack_message "${SLACK_CHANNEL_WARNING}" ":warning:  ${1}"
}

slack_debug ()
{
  send_slack_message "${SLACK_CHANNEL_DEBUG}" ":information_source:  ${1}"
}

slack_info ()
{
  send_slack_message "${SLACK_CHANNEL_INFO}" ":warning:  ${1}"
}

namespace ()
{
  # If the user set the K8S_NAMESPACE var then use that.
  # Otherwise use our current namespace
  if [ -n "${K8S_NAMESPACE}" ]; then
    echo "-n ${K8S_NAMESPACE}"
  else
    echo "-n $(cat /run/secrets/kubernetes.io/serviceaccount/namespace)"
  fi
}

secret_exists ()
{
  kubectl get secret "${1}" $(namespace) >/dev/null 2>&1
}

delete_secret_if_exists ()
{
  if secret_exists "${1}"; then
    log "Secret ${1} exists.  Deleting..."
    slack_debug "Secret ${1} exists.  Deleting..."
    kubectl delete secret "${1}" $(namespace)
  else
    log "Secret ${1} does not yet exist so no need to delete"
  fi
}

test_cert ()
{
  if [[ $TEST_CERT =~ [Yy] ]]; then
    echo "--test-cert"
  else
    echo ""
  fi
}

does_cert_exist ()
{
  log "Checking if secret exists"
  kubectl get secret "${TLS_CERT_SECRET_NAME}" $(namespace) >/dev/null 2>&1
}

has_more_time ()
{
  echo "${1}" \
    | base64 -d \
    | openssl x509 -checkend "${NUM_SECS_IN_MONTH}" -noout
}

will_cert_expire ()
{
  log "Checking if the cert in the secret is going to expire"
  tls_cert="$(kubectl get secret "${TLS_CERT_SECRET_NAME}" $(namespace) -o jsonpath={.data.TLS_CERT})"

  if [ -n "${tls_cert}" ] && has_more_time "${tls_cert}"; then
    return 1
  else
    return 0
  fi
}

replace_cert ()
{
  # We want to replace the cert if it doesn't exist, or if it expires within 30 days
  if does_cert_exist; then
    log "Secret '${TLS_CERT_SECRET_NAME}' exists.  Checking if it is within ${NUM_DAYS_BEFORE_TO_RENEW} days of expiring"
    slack_debug "Secret '${TLS_CERT_SECRET_NAME}' already contains a certificate.  Checking if expiration is within ${NUM_DAYS_BEFORE_TO_RENEW} of expiring"
    if will_cert_expire; then
      log "Certificate is within ${NUM_DAYS_BEFORE_TO_RENEW} days of expiring.  Proceeding with renewal"
      slack_debug "Certificate is within ${NUM_DAYS_BEFORE_TO_RENEW} days of expiring.  Proceeding with renewal"
      return 0
    else
      log "Certificate is not within ${NUM_DAYS_BEFORE_TO_RENEW} days of expiring.  Not proceeding with renewal"
      slack_debug "Certificate is not within ${NUM_DAYS_BEFORE_TO_RENEW} days of expiring.  Not proceeding with renewal"
      return 1
    fi
  else
    log 'Secret '${TLS_CERT_SECRET_NAME}' does not exist. Proceeding with renewal'
    slack_debug 'Secret '${TLS_CERT_SECRET_NAME}' does not exist. Proceeding with renewal'
    return 0
  fi
}

if [ -z "$CLOUDFLARE_EMAIL" ]; then
  die 'CLOUDFLARE_EMAIL env var is empty.  Set appropriately and try again'
elif [ -z "$CLOUDFLARE_API_TOKEN" ]; then
  die 'CLOUDFLARE_API_TOKEN env var is empty.  Set appropriately and try again'
elif [ -z "$DOMAINS" ]; then
  die 'DOMAINS env var is empty.  Set appropriately and try again'
elif [ -z "$TLS_CERT_SECRET_NAME" ]; then
  die 'TLS_CERT_SECRET_NAME and env vars are empty.  Set appropriately and try again'
fi

log "TLS certs will go in secret '${TLS_CERT_SECRET_NAME}' in namespace '$(namespace)'"

# Basic algo:
#  - check if target secret already exists
#  - if it does, check if expiration date within 30 days
#  - if cert is fine for now, and there's no FORCE env var set, exit success
#  - Setup cloudflare access
#  - Renew certificate with certbot
#  - Renew certificate with certbot


if [[ "$FORCE_RENEWAL" =~ [Yy] ]]; then
  log "FORCE_RENEWAL is set to ${FORCE_RENEWAL}.  Renewing"
  slack_debug "FORCE_RENEWAL is set to ${FORCE_RENEWAL}.  Renewing"
else
  log 'Checking for existing certificate'
  if ! replace_cert; then
    log "Certificate already exists and is not within ${NUM_DAYS_BEFORE_TO_RENEW} days of expiring.  Doing nothing"
    slack_info "Certificate already exists and is not within ${NUM_DAYS_BEFORE_TO_RENEW} days of expiring.  Doing nothing"
    exit 0
  fi
fi

set -e

log 'Configuring Cloudflare API access'
cd /root/
mkdir -p /root/.secrets/
touch /root/.secrets/cloudflare.ini
cat << EOF > /root/.secrets/cloudflare.ini
dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}
EOF

chmod 0700 /root/.secrets/
chmod 0400 /root/.secrets/cloudflare.ini

if [ -n "$(test_cert)" ]; then
  log "We are in test mode because env var TEST_CERT is set to '${TEST_CERT}'.  this certificate will come from the Let's Encrypt sandbox server, meaning it will not be valid from a user's perspective"
  slack_debug "In test cert mode so the certificate will come from the LE sandbox and will not be valid"
fi

log 'Beginning Lets Encrypt DNS-01 challenge'

set +e

certbot certonly $(test_cert) \
  --non-interactive \
  --force-renewal \
  --agree-tos \
  --email "${CLOUDFLARE_EMAIL}" \
  --eff-email \
  --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  --domains "${DOMAINS}" \
  --preferred-challenges dns-01

if [ "$?" != "0" ]; then
  log 'certbot failed to renew certificates'
  slack_error "Renewal of TLS certs for ${DOMAINS} failed.  certbot run exited without success.\n\nPod name: $(cat /etc/podinfo/podname)\nPod namespace: $(cat /etc/podinfo/namespace)"
  exit 2
fi

log 'Lets Encrypt DNS-01 challenge finished.  Readying for upload to k8s'
slack_debug 'Lets Encrypt DNS-01 challenge finished.  Readying for upload to k8s'

set -e 

timestamp="$(date +%Y-%m-%d-%H-%M-%S)"
outputdir="${timestamp}-tls-certs"
mkdir -p "$outputdir"
cp /etc/letsencrypt/live/*/* "${outputdir}/"
tar czvf "${outputdir}.tar.gz" "${outputdir}"
cd "${outputdir}"

set +e

delete_secret_if_exists "${TLS_CERT_SECRET_NAME}"

if [ "$?" != "0" ]; then
  log 'Error deleting existing secret'
  slack_error "Renewal of TLS certs for ${DOMAINS} failed.  Could not delete existing Secret (that contains the old certificate)\n\nPod name: $(cat /etc/podinfo/podname)\nPod namespace: $(cat /etc/podinfo/namespace)"
  exit 2
fi

log "Uploading full chain cert as secret '${TLS_CERT_SECRET_NAME}' K8s"
slack_debug "Uploading full chain cert as secret '${TLS_CERT_SECRET_NAME}' K8s"
kubectl create secret generic "${TLS_CERT_SECRET_NAME}" $(namespace) \
  --from-literal="tls.key=$(cat privkey.pem)" \
  --from-literal="tls.crt=$(cat cert.pem)" \
  --from-literal="tls.chain=$(cat chain.pem)" \
  --from-literal="tls.fullchain=$(cat chain.pem)" \
 \
  --from-literal="TLS_PRIVKEY=$(cat privkey.pem)" \
  --from-literal="TLS_FULLCHAIN=$(cat fullchain.pem)" \
  --from-literal="TLS_CHAIN=$(cat chain.pem)" \
  --from-literal="TLS_CERT=$(cat cert.pem)"


if [ "$?" != "0" ]; then
  log "Error creating new secret ${TLS_CERT_SECRET_NAME}"
  slack_error "Renewal of TLS certs for ${DOMAINS} failed.  Error uploading certs to k8s secret\n\nPod name: $(cat /etc/podinfo/podname)\nPod namespace: $(cat /etc/podinfo/namespace)"
  exit 2
fi

log "Certificate for ${DOMAINS} updated successfully."
slack_success "Renewal of TLS certs for ${DOMAINS} succeeded."

log "openssl check of the full chain cert:"
openssl x509 -noout -text -in fullchain.pem

log "openssl check of the cert only:"
openssl x509 -noout -text -in cert.pem
