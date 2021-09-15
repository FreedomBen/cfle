#!/usr/bin/env bash

LATEST_VERSION='20210915131847'

docker build \
  -f Dockerfile \
  -t "docker.io/freedomben/cfle:${LATEST_VERSION}" \
  -t "docker.io/freedomben/cfle:latest" \
  .
