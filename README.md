# Discourse on AWS with SST

This is a small configuration-as-code example for running the upstream Discourse Docker installation on one AWS EC2 instance.

SST owns the AWS resources. Discourse owns the application lifecycle through its normal `discourse_docker` installer and `launcher` commands.

## Repository layout

- `sst.config.ts` — EC2, default-VPC placement, security group, IAM, and Secrets Manager.
- `config/app.yml.template` — the single version-controlled Discourse config source.
- `infra/user-data.sh` — the one-time host bootstrap script.
- `scripts/deploy.sh` — validates required environment and Secrets Manager values, then runs SST.
- `.github/workflows/deploy.yml` — calls the same deploy script in CI.

No Discourse configuration is copied through S3 or maintained in a second generated config system.

## Required secret

Create the stage once with SST so it creates the Secrets Manager secret:

```bash
npx sst deploy --stage sample
```

The instance will wait safely if the secret is empty. Populate the secret using the ARN from the output:

```bash
export SECRET_ARN='...'
export AWS_REGION=us-west-2
./scripts/set-secrets.sh
```

The secret must contain:

```json
{
  "DISCOURSE_DB_USERNAME": "discourse",
  "DISCOURSE_DB_NAME": "discourse",
  "DISCOURSE_DB_PASSWORD": "..."
}
```

## Deploy locally or in GitHub Actions

The same script works in both places:

```bash
npm ci
export AWS_REGION=us-west-2
export SST_STAGE=sample
export DISCOURSE_HOSTNAME=forum.example.com
export DISCOURSE_ADMIN_EMAIL=admin@example.com
./scripts/deploy.sh
```

The script checks AWS authentication and all required secret fields before calling `sst deploy`. GitHub only needs AWS authentication; runtime values remain in Secrets Manager.

The first boot installs Docker, clones the upstream `discourse_docker` repository, writes `config/app.yml.template` to `/var/discourse/containers/app.yml`, renders the secret values, and runs the official launcher bootstrap.

## Redeploys and teardown

For the non-production `sample` stage, changing the checked-in config replaces the test host and bootstraps it again. This is intentionally simple and not zero-downtime. Production should use persistent external PostgreSQL/Redis and a deliberate rolling or blue/green strategy.

```bash
npx sst remove --stage sample
```

Review retained Secrets Manager secrets, snapshots, and Elastic IPs after teardown.

## References

- [Discourse cloud installation guide](https://github.com/discourse/discourse/blob/main/docs/INSTALL-cloud.md)
- [Discourse Docker repository](https://github.com/discourse/discourse_docker)
- [Community AWS deployment guide](https://meta.discourse.org/t/install-discourse-on-amazon-web-services-aws/37323?tl=en)
- [SST documentation](https://sst.dev/docs)
