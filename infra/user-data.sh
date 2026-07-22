#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/discourse-bootstrap.log | logger -t discourse-bootstrap -s 2>/dev/console) 2>&1

dnf update -y
dnf install -y docker jq git amazon-ssm-agent unzip
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi
systemctl enable --now docker
systemctl enable --now amazon-ssm-agent

if [ ! -d /var/discourse/.git ]; then
  git clone --depth 1 https://github.com/discourse/discourse_docker.git /var/discourse
else
  git -C /var/discourse fetch --depth 1 origin main
  git -C /var/discourse reset --hard origin/main
fi
mkdir -p /var/discourse/templates /var/discourse/shared/standalone

echo "__APP_CONFIG_B64__" | base64 -d > /var/discourse/templates/app.yml.template
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id '__SECRET_ARN__' --query SecretString --output text)"

if [ -z "$SECRET_JSON" ] || [ "$SECRET_JSON" = "None" ]; then
  echo "Secret is empty. Run scripts/set-secrets.sh before rebuilding Discourse."
  exit 1
fi

export DISCOURSE_DB_PASSWORD="$(jq -r .DISCOURSE_DB_PASSWORD <<<"$SECRET_JSON")"
export DISCOURSE_DB_USERNAME="$(jq -r .DISCOURSE_DB_USERNAME <<<"$SECRET_JSON")"
export DISCOURSE_DB_NAME="$(jq -r .DISCOURSE_DB_NAME <<<"$SECRET_JSON")"
sed \
  -e "s|__HOSTNAME__|__DEPLOY_HOSTNAME__|g" \
  -e "s|__ADMIN_EMAIL__|__DEPLOY_ADMIN_EMAIL__|g" \
  -e "s|__DB_PASSWORD__|$DISCOURSE_DB_PASSWORD|g" \
  -e "s|__DB_USERNAME__|$DISCOURSE_DB_USERNAME|g" \
  -e "s|__DB_NAME__|$DISCOURSE_DB_NAME|g" \
  /var/discourse/templates/app.yml.template > /var/discourse/containers/app.yml

cd /var/discourse
./launcher bootstrap app
./launcher start app
