#!/bin/bash

# Create the shared external network if it doesn't exist
docker network inspect homelab >/dev/null 2>&1 || \
docker network create homelab

echo "Prerequisites checked: 'homelab' network is ready."

# Wire up the repo's tracked git hooks (secret-scanning pre-commit, via
# gitleaks) - core.hooksPath isn't trusted from a clone automatically,
# so each clone needs to opt in once.
git config core.hooksPath .githooks
echo "Git hooks enabled: pre-commit secret scan (requires gitleaks - see README)."
