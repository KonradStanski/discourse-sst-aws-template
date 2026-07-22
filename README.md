# Discourse on AWS with SST

This is a thin, configuration-as-code example for running the upstream Discourse Docker installation on one AWS EC2 instance.

It intentionally uses the current official Discourse self-hosting path rather than creating a new Discourse packaging layer. SST provisions the AWS resources; `discourse_docker` owns the application lifecycle.

## What is version controlled

- AWS infrastructure and IAM permissions: `sst.config.ts`
- Discourse container configuration: `config/app.yml.template`
- EC2 bootstrap/update procedure: `infra/user-data.sh`
- Deployment workflow: `.github/workflows/deploy.yml`
- The upstream installer is cloned at boot and can be pinned by changing the clone/ref in `infra/user-data.sh`.

## What is not version controlled

- Forum content and database state
- AWS secret values
- The domain registration/DNS account

Secrets are stored in AWS Secrets Manager. GitHub only needs AWS deployment credentials. For production, replace the static access-key workflow with GitHub Actions OIDC and a narrowly scoped IAM role.

## Deploy

```bash
npm install
export DISCOURSE_HOSTNAME=forum.example.com
export DISCOURSE_ADMIN_EMAIL=admin@example.com
npx sst deploy --stage production
```

Copy the `secretArn` and `bucketName` outputs, create the required S3 access key, and populate Secrets Manager:

```bash
export SECRET_ARN='...'
export AWS_REGION=us-west-2
export DISCOURSE_S3_ACCESS_KEY_ID='...'
export DISCOURSE_S3_SECRET_ACCESS_KEY='...'
./scripts/set-secrets.sh
```

Then point DNS at the `url` output. The first boot installs Docker and the upstream Discourse Docker repository, fetches the versioned config template from S3, reads secrets from Secrets Manager, and bootstraps Discourse.

## Redeploys and upgrades

Changing SST infrastructure or the checked-in config is reproducible. The instance is replaced when `userDataReplaceOnChange` detects a bootstrap change. Persistent content must be restored from S3 backups or moved to external RDS for a production architecture.

This single-instance example is not zero-downtime: Discourse rebuilds briefly stop the application. Infrastructure redeploys preserve the host; after changing `config/app.yml.template`, run `/usr/local/bin/discourse-rebuild` through SSM. A production HA version should use external RDS, a managed Redis service, shared object storage, and a blue/green EC2 or ECS rollout behind an ALB.

Example SSM rebuild command:

```bash
aws ssm send-command --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters commands='["/usr/local/bin/discourse-rebuild"]' \
  --region "$AWS_REGION"
```

## Teardown

```bash
npx sst remove --stage production
```

Review S3 objects, snapshots, Elastic IPs, and Secrets Manager recovery windows separately. Do not leave a detached public IPv4 address or retained production secret unintentionally.

## Upstream references

- [Discourse cloud installation guide](https://github.com/discourse/discourse/blob/main/docs/INSTALL-cloud.md)
- [Discourse Docker repository](https://github.com/discourse/discourse_docker)
- [Community AWS deployment guide](https://meta.discourse.org/t/install-discourse-on-amazon-web-services-aws/37323?tl=en)
- [SST documentation](https://sst.dev/docs)
