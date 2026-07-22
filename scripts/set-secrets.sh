#!/bin/bash
set -euo pipefail

: "${SECRET_ARN:?Set SECRET_ARN to the SST output secret ARN}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${DISCOURSE_S3_ACCESS_KEY_ID:?Set the S3 access key ID}"
: "${DISCOURSE_S3_SECRET_ACCESS_KEY:?Set the S3 secret access key}"

read -rsp "Database password: " DB_PASSWORD
echo
read -rsp "Redis password: " REDIS_PASSWORD
echo

python3 - "$SECRET_ARN" "$AWS_REGION" "$DISCOURSE_S3_ACCESS_KEY_ID" "$DISCOURSE_S3_SECRET_ACCESS_KEY" "$DB_PASSWORD" "$REDIS_PASSWORD" <<'PY'
import json
import subprocess
import sys

secret_arn, region, s3_id, s3_secret, db_password, redis_password = sys.argv[1:]
payload = {
    "DISCOURSE_DB_USERNAME": "discourse",
    "DISCOURSE_DB_NAME": "discourse",
    "DISCOURSE_DB_PASSWORD": db_password,
    "DISCOURSE_REDIS_PASSWORD": redis_password,
    "DISCOURSE_S3_ACCESS_KEY_ID": s3_id,
    "DISCOURSE_S3_SECRET_ACCESS_KEY": s3_secret,
}
subprocess.run([
    "aws", "secretsmanager", "put-secret-value",
    "--secret-id", secret_arn,
    "--secret-string", json.dumps(payload),
    "--region", region,
], check=True)
PY

echo "Secret updated. Re-run the instance bootstrap or trigger a rebuild through SSM."
