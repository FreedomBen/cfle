#!/usr/bin/env bash

LATEST_VERSION='20211004184552'

docker push "docker.io/freedomben/cfle:${LATEST_VERSION}"
docker push "docker.io/freedomben/cfle:latest"
