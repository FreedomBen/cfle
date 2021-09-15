#!/usr/bin/env bash

SECRET_NAME='tls-cert'

kubectl get secrets "${SECRET_NAME}" -o jsonpath={.data.SSL_CERT} \
  | base64 -d \
  | openssl x509 -noout -text
