#!/usr/bin/env bash

LATEST_VERSION='20210915120902'

docker push "docker.io/freedomben/cfle:${LATEST_VERSION}"
docker push "docker.io/freedomben/cfle:latest"
