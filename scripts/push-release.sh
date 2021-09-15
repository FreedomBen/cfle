#!/usr/bin/env bash

LATEST_VERSION='20210915131847'

docker push "docker.io/freedomben/cfle:${LATEST_VERSION}"
docker push "docker.io/freedomben/cfle:latest"
