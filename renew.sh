#!/usr/bin/env bash

# Example Env vars:
#CLOUDFLARE_EMAIL='ben@example.com'
#CLOUDFLARE_API_TOKEN='awekjltaSAGKLHG'
#ROOT_DOMAIN='example.com'
#WILDCARD_DOMAIN='*.example.com'

die ()
{
  echo "[DIE] - $(date): ${1}"
  exit 1
}

log ()
{
  echo "[LOG] - $(date): ${1}"
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

if [ -z "$CLOUDFLARE_EMAIL" ]; then
  die 'CLOUDFLARE_EMAIL env var is empty.  Set appropriately and try again'
elif [ -z "$CLOUDFLARE_API_TOKEN" ]; then
  die 'CLOUDFLARE_API_TOKEN env var is empty.  Set appropriately and try again'
elif [ -z "$ROOT_DOMAIN" ]; then
  die 'ROOT_DOMAIN env var is empty.  Set appropriately and try again'
elif [ -z "$WILDCARD_DOMAIN" ]; then
  die 'WILDCARD_DOMAIN env var is empty.  Set appropriately and try again'
elif [ -z "$SECRET_NAME_FULL_CHAIN" ]; then
  die 'SECRET_NAME_FULL_CHAIN env var is empty.  Set appropriately and try again'
elif [ -z "$SECRET_NAME_CERT_ONLY" ]; then
  die 'SECRET_NAME_CERT_ONLY env var is empty.  Set appropriately and try again'
fi

set -e

log 'Configuring Cloudflare API access'
cd /root/
mkdir -p /root/.secrets/
touch /root/.secrets/cloudflare.ini

#cat << EOF > /root/.secrets/cloudflare.ini
#dns_cloudflare_email = ${CLOUDFLARE_EMAIL}
#dns_cloudflare_api_key = ${CLOUDFLARE_API_KEY}
#EOF

cat << EOF > /root/.secrets/cloudflare.ini
dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}
EOF

chmod 0700 /root/.secrets/
chmod 0400 /root/.secrets/cloudflare.ini

if [ -n "$(test_cert)" ]; then
  log "We are in test mode because env var TEST_CERT is set to '${TEST_CERT}'.  this certificate will come from the Let's Encrypt sandbox server, meaning it will not be valid from a user's perspective"
fi

log 'Beginning Lets Encrypt DNS-01 challenge'

certbot certonly $(test_cert) \
  --non-interactive \
  --force-renewal \
  --agree-tos \
  --email "${CLOUDFLARE_EMAIL}" \
  --eff-email \
  --dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  --domains "${ROOT_DOMAIN},${WILDCARD_DOMAIN}" \
  --preferred-challenges dns-01

log 'Lets Encrypt DNS-01 challenge finished.  Readying for upload to k8s'

timestamp="$(date +%Y-%m-%d-%H-%M-%S)"
outputdir="${timestamp}-tls-certs"
mkdir -p "$outputdir"
cp /etc/letsencrypt/live/*/* "${outputdir}/"
tar czvf "${outputdir}.tar.gz" "${outputdir}"
cd "${outputdir}"


delete_secret_if_exists "${SECRET_NAME_FULL_CHAIN}"

log "Uploading full chain cert as secret '${SECRET_NAME_FULL_CHAIN}' K8s"
kubectl create secret generic "${SECRET_NAME_FULL_CHAIN}" $(namespace) \
  --from-literal="tls.key=$(cat privkey.pem)" \
  --from-literal="tls.crt=$(cat fullchain.pem)" \
  --from-literal="SSL_KEY=$(cat privkey.pem)" \
  --from-literal="SSL_CERT=$(cat fullchain.pem)"

delete_secret_if_exists "${SECRET_NAME_CERT_ONLY}"

log "Uploading full chain cert as secret '${SECRET_NAME_CERT_ONLY}' K8s"
kubectl create secret generic "${SECRET_NAME_CERT_ONLY}" $(namespace) \
  --from-literal="tls.key=$(cat privkey.pem)" \
  --from-literal="tls.crt=$(cat cert.pem)" \
  --from-literal="SSL_KEY=$(cat privkey.pem)" \
  --from-literal="SSL_CERT=$(cat cert.pem)"

log "Certificate for ${ROOT_DOMAIN} and ${WILDCARD_DOMAIN} updated successfully."

log "openssl check of the full chain cert:"
openssl x509 -noout -text -in fullchain.pem

log "openssl check of the cert only:"
openssl x509 -noout -text -in cert.pem

log "Sleeping for a while for examination"
sleep 60000
