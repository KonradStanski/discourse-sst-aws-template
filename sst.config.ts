/// <reference path="./.sst/platform/config.d.ts" />

export default $config({
  app() {
    return {
      name: "discourse-sst-aws",
      home: "aws",
      providers: { aws: { region: "us-west-2" } },
    };
  },

  async run() {
    const aws = await import("@pulumi/aws");
    const pulumi = await import("@pulumi/pulumi");
    const { readFileSync } = await import("node:fs");

    const region = process.env.AWS_REGION ?? "us-west-2";
    const hostname = process.env.DISCOURSE_HOSTNAME ?? "forum.example.com";
    const adminEmail = process.env.DISCOURSE_ADMIN_EMAIL ?? "admin@example.com";
    const configTemplate = readFileSync("config/app.yml.template").toString("base64");

    const vpc = await aws.ec2.getVpc({ default: true });
    const subnets = await aws.ec2.getSubnets({ filters: [{ name: "vpc-id", values: [vpc.id] }] });
    const subnetId = subnets.ids[0];

    const secret = new aws.secretsmanager.Secret("DiscourseSecrets", {
      name: `${$app.name}/${$app.stage}/discourse`,
      description: "Discourse runtime secrets; values are managed in Secrets Manager.",
      recoveryWindowInDays: $app.stage === "production" ? 30 : 7,
    });

    const securityGroup = new aws.ec2.SecurityGroup("DiscourseSecurityGroup", {
      vpcId: vpc.id,
      description: "Public Discourse HTTP/HTTPS; administration uses SSM.",
      ingress: [
        { protocol: "tcp", fromPort: 80, toPort: 80, cidrBlocks: ["0.0.0.0/0"] },
        { protocol: "tcp", fromPort: 443, toPort: 443, cidrBlocks: ["0.0.0.0/0"] },
      ],
      egress: [{ protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"] }],
    });

    const role = new aws.iam.Role("DiscourseInstanceRole", {
      assumeRolePolicy: aws.iam.assumeRolePolicyForPrincipal({ Service: "ec2.amazonaws.com" }),
    });
    new aws.iam.RolePolicyAttachment("DiscourseSsmPolicy", {
      role: role.name,
      policyArn: "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    });
    new aws.iam.RolePolicy("DiscourseSecretsPolicy", {
      role: role.id,
      policy: secret.arn.apply((secretArn) => JSON.stringify({
        Version: "2012-10-17",
        Statement: [{ Effect: "Allow", Action: ["secretsmanager:GetSecretValue"], Resource: secretArn }],
      })),
    });
    const profile = new aws.iam.InstanceProfile("DiscourseInstanceProfile", { role: role.name });

    const ami = await aws.ec2.getAmi({
      mostRecent: true,
      owners: ["amazon"],
      filters: [
        { name: "name", values: ["al2023-ami-*-arm64"] },
        { name: "state", values: ["available"] },
      ],
    });

    const userData = pulumi.all([secret.arn]).apply(([secretArn]) => readFileSync("infra/user-data.sh", "utf8")
      .replaceAll("__SECRET_ARN__", secretArn)
      .replaceAll("__APP_CONFIG_B64__", configTemplate)
      .replaceAll("__DEPLOY_HOSTNAME__", hostname)
      .replaceAll("__DEPLOY_ADMIN_EMAIL__", adminEmail)
      .replaceAll("__DEPLOY_REGION__", region));

    const instance = new aws.ec2.Instance("Discourse", {
      ami: ami.id,
      instanceType: $app.stage === "production" ? "t4g.medium" : "t4g.small",
      subnetId,
      vpcSecurityGroupIds: [securityGroup.id],
      iamInstanceProfile: profile.name,
      userData,
      userDataReplaceOnChange: $app.stage !== "production",
      rootBlockDevice: { volumeSize: 30, volumeType: "gp3", encrypted: true },
      tags: { Name: `${$app.name}-${$app.stage}` },
    });

    const address = new aws.ec2.Eip("DiscourseIp", { domain: "vpc" });
    new aws.ec2.EipAssociation("DiscourseIpAssociation", {
      instanceId: instance.id,
      allocationId: address.id,
    });

    return {
      url: pulumi.interpolate`http://${address.publicIp}`,
      instanceId: instance.id,
      secretArn: secret.arn,
    };
  },
});
