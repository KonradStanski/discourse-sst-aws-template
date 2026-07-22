#!/bin/bash
set -euo pipefail

: "${SECRET_ARN:?Set SECRET_ARN to the SST output secret ARN}"
: "${AWS_REGION:?Set AWS_REGION}"
read -rsp "Database password: " DB_PASSWORD
echo
python3 - "$SECRET_ARN" "$AWS_REGION" "$DB_PASSWORD" <<'PY'
import json
import subprocess
import sys

secret_arn, region, db_password = sys.argv[1:]
payload = {
    "DISCOURSE_DB_USERNAME": "discourse",
    "DISCOURSE_DB_NAME": "discourse",
    "DISCOURSE_DB_PASSWORD": db_password,
}
subprocess.run([
    "aws", "secretsmanager", "put-secret-value",
    "--secret-id", secret_arn,
    "--secret-string", json.dumps(payload),
    "--region", region,
], check=True)
PY

echo "Secret updated. Re-run the instance bootstrap or trigger a rebuild through SSM."
