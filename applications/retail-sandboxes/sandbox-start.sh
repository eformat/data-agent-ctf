#!/bin/bash
# Wait for supervisor relay to be ready before starting Hermes.
# Gitops-created sandboxes start immediately; the relay needs ~15-20s.
sleep 30
exec /usr/local/bin/hermes-start.sh
