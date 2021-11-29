#!/usr/bin/env bash

if [ -z "${RELEASE_VERSION}" ]; then
  RELEASE_VERSION="$(git rev-parse HEAD)"
fi

docker push "docker.io/freedomben/cfle:latest"
docker push "docker.io/freedomben/cfle:${RELEASE_VERSION}"

