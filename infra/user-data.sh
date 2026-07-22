#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/discourse-bootstrap.log | logger -t discourse-bootstrap -s 2>/dev/console) 2>&1

dnf update -y
dnf install -y docker awscli2 jq git
systemctl enable --now docker

mkdir -p /var/discourse/templates /var/discourse/shared/standalone
if [ ! -d /var/discourse/.git ]; then
  git clone --depth 1 https://github.com/discourse/discourse_docker.git /var/discourse
else
  git -C /var/discourse fetch --depth 1 origin main
  git -C /var/discourse reset --hard origin/main
fi

aws s3 cp s3://__BUCKET__/__CONFIG_OBJECT__ /var/discourse/templates/app.yml.template
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id '__SECRET_ARN__' --query SecretString --output text)"

if [ -z "$SECRET_JSON" ] || [ "$SECRET_JSON" = "None" ]; then
  echo "Secret is empty. Run scripts/set-secrets.sh before rebuilding Discourse."
  exit 1
fi

export DISCOURSE_DB_PASSWORD="$(jq -r .DISCOURSE_DB_PASSWORD <<<"$SECRET_JSON")"
export DISCOURSE_DB_USERNAME="$(jq -r .DISCOURSE_DB_USERNAME <<<"$SECRET_JSON")"
export DISCOURSE_DB_NAME="$(jq -r .DISCOURSE_DB_NAME <<<"$SECRET_JSON")"
export DISCOURSE_REDIS_PASSWORD="$(jq -r .DISCOURSE_REDIS_PASSWORD <<<"$SECRET_JSON")"
export DISCOURSE_S3_ACCESS_KEY_ID="$(jq -r .DISCOURSE_S3_ACCESS_KEY_ID <<<"$SECRET_JSON")"
export DISCOURSE_S3_SECRET_ACCESS_KEY="$(jq -r .DISCOURSE_S3_SECRET_ACCESS_KEY <<<"$SECRET_JSON")"

cat > /usr/local/bin/discourse-rebuild <<'REBUILD'
#!/bin/bash
set -euo pipefail
SECRET_JSON="$(aws secretsmanager get-secret-value --secret-id '__SECRET_ARN__' --query SecretString --output text)"
export DISCOURSE_DB_PASSWORD="$(jq -r .DISCOURSE_DB_PASSWORD <<<"$SECRET_JSON")"
export DISCOURSE_DB_USERNAME="$(jq -r .DISCOURSE_DB_USERNAME <<<"$SECRET_JSON")"
export DISCOURSE_DB_NAME="$(jq -r .DISCOURSE_DB_NAME <<<"$SECRET_JSON")"
export DISCOURSE_REDIS_PASSWORD="$(jq -r .DISCOURSE_REDIS_PASSWORD <<<"$SECRET_JSON")"
export DISCOURSE_S3_ACCESS_KEY_ID="$(jq -r .DISCOURSE_S3_ACCESS_KEY_ID <<<"$SECRET_JSON")"
export DISCOURSE_S3_SECRET_ACCESS_KEY="$(jq -r .DISCOURSE_S3_SECRET_ACCESS_KEY <<<"$SECRET_JSON")"
aws s3 cp s3://__BUCKET__/__CONFIG_OBJECT__ /var/discourse/templates/app.yml.template
sed -e "s|__S3_BUCKET__|__BUCKET__|g" -e "s|__AWS_REGION__|__AWS_REGION__|g" \
  -e "s|__HOSTNAME__|__HOSTNAME__|g" -e "s|__ADMIN_EMAIL__|__ADMIN_EMAIL__|g" \
  -e "s|__DB_PASSWORD__|$DISCOURSE_DB_PASSWORD|g" -e "s|__DB_USERNAME__|$DISCOURSE_DB_USERNAME|g" \
  -e "s|__DB_NAME__|$DISCOURSE_DB_NAME|g" -e "s|__REDIS_PASSWORD__|$DISCOURSE_REDIS_PASSWORD|g" \
  -e "s|__S3_ACCESS_KEY_ID__|$DISCOURSE_S3_ACCESS_KEY_ID|g" \
  -e "s|__S3_SECRET_ACCESS_KEY__|$DISCOURSE_S3_SECRET_ACCESS_KEY|g" \
  /var/discourse/templates/app.yml.template > /var/discourse/containers/app.yml
cd /var/discourse
./launcher rebuild app
REBUILD
chmod 700 /usr/local/bin/discourse-rebuild

sed \
  -e "s|__S3_BUCKET__|__BUCKET__|g" \
  -e "s|__AWS_REGION__|__AWS_REGION__|g" \
  -e "s|__HOSTNAME__|__HOSTNAME__|g" \
  -e "s|__ADMIN_EMAIL__|__ADMIN_EMAIL__|g" \
  -e "s|__DB_PASSWORD__|$DISCOURSE_DB_PASSWORD|g" \
  -e "s|__DB_USERNAME__|$DISCOURSE_DB_USERNAME|g" \
  -e "s|__DB_NAME__|$DISCOURSE_DB_NAME|g" \
  -e "s|__REDIS_PASSWORD__|$DISCOURSE_REDIS_PASSWORD|g" \
  -e "s|__S3_ACCESS_KEY_ID__|$DISCOURSE_S3_ACCESS_KEY_ID|g" \
  -e "s|__S3_SECRET_ACCESS_KEY__|$DISCOURSE_S3_SECRET_ACCESS_KEY|g" \
  /var/discourse/templates/app.yml.template > /var/discourse/containers/app.yml

cd /var/discourse
./launcher bootstrap app
./launcher start app
