#!/bin/bash
docker buildx build -f Dockerfile.ubuntu --platform linux/amd64,linux/arm64 -t cdalar/ubuntu:latest --push .
