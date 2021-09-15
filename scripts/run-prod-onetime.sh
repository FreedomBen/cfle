#!/usr/bin/env bash

CRONJOB_NAME='tls-cert-renewal'
NEW_JOB_NAME="tls-cert-renewal-manual-run-$(date '+%Y-%m-%d-%H-%M-%S')"

echo "Running CronJob/${CRONJOB_NAME} one time as Job/${NEW_JOB_NAME}"
echo "=> kubectl create job --from=cronjob/${CRONJOB_NAME} ${NEW_JOB_NAME}"

kubectl create job --from="cronjob/${CRONJOB_NAME}" "${NEW_JOB_NAME}"
