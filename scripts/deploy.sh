#!/bin/bash
set -euo pipefail

: "${AWS_REGION:=us-west-2}"
: "${SST_STAGE:=sample}"
: "${DISCOURSE_HOSTNAME:?Set DISCOURSE_HOSTNAME}"
: "${DISCOURSE_ADMIN_EMAIL:?Set DISCOURSE_ADMIN_EMAIL}"

SECRET_ID="${DISCOURSE_SECRET_ID:-discourse-sst-aws/${SST_STAGE}/discourse}"

aws sts get-caller-identity >/dev/null
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text)"

for key in DISCOURSE_DB_USERNAME DISCOURSE_DB_NAME DISCOURSE_DB_PASSWORD; do
  value="$(jq -r --arg key "$key" '.[$key] // empty' <<<"$SECRET_JSON")"
  [ -n "$value" ] || { echo "Missing $key in Secrets Manager secret $SECRET_ID" >&2; exit 1; }
done

echo "Deploying Discourse stage $SST_STAGE with secret $SECRET_ID"
npx sst deploy --stage "$SST_STAGE"
