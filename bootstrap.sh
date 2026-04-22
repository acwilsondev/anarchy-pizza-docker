#!/bin/bash

# Create the shared external network if it doesn't exist
docker network inspect anarchy-pizza >/dev/null 2>&1 || \
docker network create anarchy-pizza

echo "Prerequisites checked: 'anarchy-pizza' network is ready."
