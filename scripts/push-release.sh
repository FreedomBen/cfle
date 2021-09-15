#!/usr/bin/env bash

LATEST_VERSION='20210915122858'

docker push "docker.io/freedomben/cfle:${LATEST_VERSION}"
docker push "docker.io/freedomben/cfle:latest"
