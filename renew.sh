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

#DIE_DELAY_SECS='28800' # seconds to sleep before exiting on failure. 28800 is 8 hours

#set -o nounset  # Uncomment for debugging

# Use `help declare` to get more info about declare options
declare -r NUM_SECS_IN_MONTH=2592000  # month == 30 days, 60 * 60 * 24 * 30

TLS_CERT=''  # Make TLS_CERT a global

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
  local exit_code="${1:-99}"
  local msg="${2}"
  if ! [[ $exit_code =~ ^-?[0-9]+$ ]]; then
    echo "Warning: exit code provided to die() was not an integer.  Defaulting to 98"
    exit_code=98
    if [ -z "${2}" ]; then
      echo "Using arg 1 as message since one was not provided"
      msg="${1}"
    fi
  fi
  echo "[DIE] Exit code '${exit_code}' - $(date): ${msg}"
  slack_error "${msg}"
  if [ -n "${DIE_DELAY_SECS}" ]; then
    echo "DIE_DELAY_SECS is set.  Delaying exit by sleeping for ${DIE_DELAY_SECS} seconds"
    sleep "${DIE_DELAY_SECS}"
  else
    echo "DIE_DELAY_SECS is not set.  To delay exit, set DIE_DELAY_SECS"
  fi
  exit ${exit_code}
}

log ()
{
  echo -e "[LOG] - $(date): ${1}"
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
  if [ -n "${SLACK_API_TOKEN}" ]; then
    log "SLACK_API_TOKEN is set.  sending slack message to channel ${1}"
    curl \
      --silent \
      --show-error \
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

# May want to consider uploading additional logs like
# /var/log/letsencrypt/letsencrypt.log using files.upload endpoint
#   https://api.slack.com/methods/files.upload
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
  send_slack_message "${SLACK_CHANNEL_INFO}" ":information_source:  ${1}"
}

certbot_failure_message ()
{
  echo -e "Renewal of TLS cert for ${DOMAINS} failed\nCertbot DNS-01 Challenge failed (exited with status code '${1:-unknown}').  See logs for details\n\nCheck logs with kubectl logs $(cat /etc/podinfo/podname) -n $(cat /etc/podinfo/namespace)"
}

renewal_failure_message ()
{
  echo -e "Renewal of TLS cert for ${DOMAINS} failed\nCert expires on **$(cert_expire_date "fullchain.pem")**\n${1}\nCheck logs with kubectl logs $(cat /etc/podinfo/podname) -n $(cat /etc/podinfo/namespace)"
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
  if [ -z "${TEST_CERT}" ] || [[ $TEST_CERT =~ [Nn] ]]; then
    echo ""
  else
    echo "--test-cert"
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
    | openssl x509 -checkend "$(num_secs_until_expire)" -noout
}

tls_cert ()
{
  if [ -n "${TLS_CERT}" ]; then
    echo "${TLS_CERT}"
  else
    # Retrieve cert from k8s secret
    TLS_CERT="$(kubectl get secret "${TLS_CERT_SECRET_NAME}" $(namespace) -o jsonpath={.data.TLS_CERT})"
    echo "${TLS_CERT}"
  fi
}

cert_expire_date ()
{
  cat "${1}" \
    | base64 -d \
    | openssl x509 -enddate -noout \
    | sed -E -e 's/^notAfter=//g'
}

will_cert_expire ()
{
  log "Checking if the cert in the secret is going to expire"

  if [ -n "$(tls_cert)" ] && has_more_time "$(tls_cert)"; then
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
  die '3' 'CFLE cannot renew Lets Encypt certificate because the CLOUDFLARE_EMAIL env var is empty.  Set appropriately and try again'
elif [ -z "$CLOUDFLARE_API_TOKEN" ]; then
  die '4' 'CFLE cannot renew Lets Encypt certificate because the CLOUDFLARE_API_TOKEN env var is empty.  Set appropriately and try again'
elif [ -z "$DOMAINS" ]; then
  die '5' 'CFLE cannot renew Lets Encypt certificate because the DOMAINS env var is empty.  Set appropriately and try again'
elif [ -z "$TLS_CERT_SECRET_NAME" ]; then
  die '6' 'CFLE cannot renew Lets Encypt certificate because the TLS_CERT_SECRET_NAME and env vars are empty.  Set appropriately and try again'
fi

log "TLS certs will go in secret '${TLS_CERT_SECRET_NAME}' in namespace '$(namespace)'"

# Basic algo:
#  - verify target k8s namespace exists
#  - check if target secret already exists
#  - if it does, check if expiration date within 30 days
#  - if cert is fine for now, and there's no FORCE env var set, exit success
#  - Setup cloudflare access
#  - Renew certificate with certbot
#  - Renew certificate with certbot

log "Checking that target namespace '${K8S_NAMESPACE}' exists"
log "all namespaces:"

log "\n\n$(kubectl get namespaces)\n\n"
if kubectl get namespace "${K8S_NAMESPACE}" >/dev/null 2>&1; then
  log "Namespace '${K8S_NAMESPACE}' exists.  Continuing"
else
  # Should we create the namespace?  Might not have RBAC capability to create a ns
  die '10' "Namespace '${K8S_NAMESPACE}' does NOT exist.  Please create it and try again:  `kubectl create namespace '${K8S_NAMESPACE}'`"
fi

if [[ "$FORCE_RENEWAL" =~ [Yy] ]]; then
  log "FORCE_RENEWAL is set to ${FORCE_RENEWAL}.  Renewing"
  slack_debug "FORCE_RENEWAL is set to ${FORCE_RENEWAL}.  Renewing"
else
  log 'Checking for existing certificate'
  if ! replace_cert; then
    log "Certificate already exists in secret '${TLS_CERT_SECRET_NAME}' and is not within ${NUM_DAYS_BEFORE_TO_RENEW} days of expiring.  Doing nothing"
    slack_info "Certificate already exists in secret '${TLS_CERT_SECRET_NAME}' and is not within ${NUM_DAYS_BEFORE_TO_RENEW} days of expiring.  Doing nothing"
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
  log "We ARE in test mode because env var TEST_CERT is set to something besides empty or 'No' ('${TEST_CERT}').  this certificate will come from the Let's Encrypt sandbox server, meaning it will not be valid from a user's perspective"
  slack_debug "In test cert mode so the certificate will come from the LE sandbox and will not be valid"
else
  log "We are NOT in test mode because env var TEST_CERT is not set.  This certificate will come from the real Let's Encrypt server and is subject to rate limiting"
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
  --dns-cloudflare-propagation-seconds 30 \
  --domains "${DOMAINS}" \
  --preferred-challenges dns-01

if [ "$?" != "0" ]; then
  status_code="$?"
  log 'certbot failed to renew certificates'
  die '7' "$(certbot_failure_message "$status_code")"
fi

log 'Lets Encrypt DNS-01 challenge finished.  Readying for upload to k8s'
slack_debug "Lets Encrypt DNS-01 challenge finished.  Readying for upload to k8s in secret '${TLS_CERT_SECRET_NAME}'"

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
  die '8' "$(renewal_failure_message "Could not delete existing Secret '${TLS_CERT_SECRET_NAME}' (that contains the old certificate)")"
fi

log "Uploading full chain cert as secret '${TLS_CERT_SECRET_NAME}' to K8s"
slack_debug "Uploading full chain cert as secret '${TLS_CERT_SECRET_NAME}' to K8s"
kubectl create secret generic "${TLS_CERT_SECRET_NAME}" $(namespace) \
  --from-literal="tls.key=$(cat privkey.pem)" \
  --from-literal="tls.crt=$(cat cert.pem)" \
  --from-literal="tls.chain=$(cat chain.pem)" \
  --from-literal="tls.fullchain=$(cat fullchain.pem)" \
 \
  --from-literal="TLS_PRIVKEY=$(cat privkey.pem)" \
  --from-literal="TLS_CERT=$(cat cert.pem)" \
  --from-literal="TLS_CHAIN=$(cat chain.pem)" \
  --from-literal="TLS_FULLCHAIN=$(cat fullchain.pem)"


if [ "$?" != "0" ]; then
  log "Error creating new secret ${TLS_CERT_SECRET_NAME}"
  die '9' "$(renewal_failure_message "Error creating k8s secret '${TLS_CERT_SECRET_NAME}'")"
fi

log "Certificate for ${DOMAINS} updated successfully.  Cert placed in secret '${TLS_CERT_SECRET_NAME}'"
slack_success "Renewal of TLS certs for ${DOMAINS} succeeded.  Cert placed in secret '${TLS_CERT_SECRET_NAME}'.  Expires on **$(cert_expire_date "fullchain.pem")**"

log "openssl check of the full chain cert:"
openssl x509 -noout -text -in fullchain.pem

log "openssl check of the cert only:"
openssl x509 -noout -text -in cert.pem
