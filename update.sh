#!/bin/bash

if [ $1 == "-h" ]; then
  echo "Usage: ./restart.sh [service]"
  echo "  service: the service to restart, or all if not specified"
  exit 0
fi

if [ -z $1 ]; then
  for file in docker-compose.*.yml; do
    docker-compose -f $file down
    docker-compose -f $file up -d
  done
  exit 0
fi

# otherwise, just restart $1

docker-compose -f docker-compose.$1.yml down
docker-compose -f docker-compose.$1.yml up -d
