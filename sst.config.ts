/// <reference path="./.sst/platform/config.d.ts" />

import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";
import { readFileSync } from "node:fs";

export default $config({
  app(input) {
    return {
      name: "discourse-sst-aws",
      home: "aws",
      providers: {
        aws: {
          region: input?.stage === "production" ? "us-west-2" : "us-west-2",
        },
      },
      removal: input?.stage === "production" ? "retain" : "remove",
    };
  },
  async run() {
    const config = {
      hostname: process.env.DISCOURSE_HOSTNAME ?? "forum.example.com",
      adminEmail: process.env.DISCOURSE_ADMIN_EMAIL ?? "admin@example.com",
      region: process.env.AWS_REGION ?? "us-west-2",
    };

    const bucket = new aws.s3.Bucket("DiscourseData", {
      forceDestroy: $app.stage !== "production",
      versioning: { enabled: true },
      serverSideEncryptionConfiguration: {
        rule: { applyServerSideEncryptionByDefault: { sseAlgorithm: "AES256" } },
      },
    });

    const configObject = new aws.s3.BucketObject("DiscourseConfig", {
      bucket: bucket.id,
      key: "discourse/app.yml.template",
      content: readFileSync("config/app.yml.template", "utf8"),
      contentType: "text/yaml",
    });

    const secret = new aws.secretsmanager.Secret("DiscourseSecrets", {
      name: `${$app.name}/${$app.stage}/discourse`,
      description: "Runtime Discourse secrets. Values are managed outside Git.",
      recoveryWindowInDays: $app.stage === "production" ? 30 : 7,
    });

    const vpc = new aws.ec2.Vpc("DiscourseVpc", {
      cidrBlock: "10.42.0.0/16",
      enableDnsHostnames: true,
      enableDnsSupport: true,
      tags: { Name: `${$app.name}-${$app.stage}` },
    });
    const subnet = new aws.ec2.Subnet("DiscourseSubnet", {
      vpcId: vpc.id,
      cidrBlock: "10.42.1.0/24",
      availabilityZone: `${config.region}a`,
      mapPublicIpOnLaunch: true,
    });
    const internetGateway = new aws.ec2.InternetGateway("DiscourseIgw", { vpcId: vpc.id });
    const routeTable = new aws.ec2.RouteTable("DiscourseRoutes", {
      vpcId: vpc.id,
      routes: [{ cidrBlock: "0.0.0.0/0", gatewayId: internetGateway.id }],
    });
    new aws.ec2.RouteTableAssociation("DiscourseRouteAssociation", {
      subnetId: subnet.id,
      routeTableId: routeTable.id,
    });

    const securityGroup = new aws.ec2.SecurityGroup("DiscourseSecurityGroup", {
      vpcId: vpc.id,
      description: "Public HTTP/HTTPS; administrative access uses SSM.",
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
    new aws.iam.RolePolicy("DiscourseRuntimePolicy", {
      role: role.id,
      policy: pulumi.all([secret.arn, bucket.arn]).apply(([secretArn, bucketArn]) => JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Action: ["secretsmanager:GetSecretValue"],
            Resource: secretArn,
          },
          {
            Effect: "Allow",
            Action: ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
            Resource: [bucketArn, `${bucketArn}/*`],
          },
        ],
      })),
    });
    const instanceProfile = new aws.iam.InstanceProfile("DiscourseInstanceProfile", { role: role.name });
    const ami = await aws.ec2.getAmi({
      mostRecent: true,
      owners: ["amazon"],
      filters: [
        { name: "name", values: ["al2023-ami-*-arm64"] },
        { name: "state", values: ["available"] },
      ],
    });

    const userData = pulumi.all([bucket.bucket, configObject.key, secret.arn]).apply(
      ([bucketName, configKey, secretArn]) => readFileSync("infra/user-data.sh", "utf8")
        .replaceAll("__BUCKET__", bucketName)
        .replaceAll("__CONFIG_OBJECT__", configKey)
        .replaceAll("__SECRET_ARN__", secretArn)
        .replaceAll("__HOSTNAME__", config.hostname)
        .replaceAll("__ADMIN_EMAIL__", config.adminEmail)
        .replaceAll("__AWS_REGION__", config.region),
    );

    const instance = new aws.ec2.Instance("Discourse", {
      ami: ami.id,
      instanceType: $app.stage === "production" ? "t4g.medium" : "t4g.small",
      subnetId: subnet.id,
      vpcSecurityGroupIds: [securityGroup.id],
      iamInstanceProfile: instanceProfile.name,
      userData,
      // Keep the host and its local Discourse data across config changes.
      // Apply app.yml changes with the SSM rebuild command documented in README.
      userDataReplaceOnChange: false,
      rootBlockDevice: { volumeSize: 30, volumeType: "gp3", encrypted: true },
      tags: { Name: `${$app.name}-${$app.stage}` },
    });
    const address = new aws.ec2.Eip("DiscourseIp", { domain: "vpc" });
    new aws.ec2.EipAssociation("DiscourseIpAssociation", { instanceId: instance.id, allocationId: address.id });

    return {
      url: pulumi.interpolate`http://${address.publicIp}`,
      instanceId: instance.id,
      secretArn: secret.arn,
      bucketName: bucket.bucket,
      warning: "Configure DNS to the displayed IP and set the AWS Secrets Manager value before first boot.",
    };
  },
});
