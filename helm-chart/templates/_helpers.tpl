{{/*
Expand the name of the chart.
*/}}
{{- define "pulumi-operator-aws.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pulumi-operator-aws.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pulumi-operator-aws.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pulumi-operator-aws.labels" -}}
helm.sh/chart: {{ include "pulumi-operator-aws.chart" . }}
{{ include "pulumi-operator-aws.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pulumi-operator-aws.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pulumi-operator-aws.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "pulumi-operator-aws.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "pulumi-operator-aws.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Pulumi program TypeScript code
*/}}
{{- define "pulumi-operator-aws.pulumi-program" -}}
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

// Get configuration values
const config = new pulumi.Config();
const projectName = config.get("projectName") || "{{ .Values.project.name }}";
const environment = config.get("environment") || "{{ .Values.project.environment }}";
const bucketName = config.get("bucketName") || `${projectName}-${environment}-bucket`;
const tags = config.getObject<Record<string, string>>("tags") || {
    Environment: environment,
    Project: projectName,
    ManagedBy: "pulumi-kubernetes-operator"
};

// Create an S3 bucket with versioning
const bucket = new aws.s3.Bucket("demo-bucket", {
    bucket: bucketName,
    versioning: {
        enabled: true,
    },
    serverSideEncryptionConfiguration: {
        rule: {
            applyServerSideEncryptionByDefault: {
                sseAlgorithm: "AES256",
            },
        },
    },
    tags: {
        ...tags,
        Name: `${projectName}-${environment}-bucket`,
    },
});

// Block all public access to the S3 bucket
const bucketPublicAccessBlock = new aws.s3.BucketPublicAccessBlock("demo-bucket-pab", {
    bucket: bucket.id,
    blockPublicAcls: true,
    blockPublicPolicy: true,
    ignorePublicAcls: true,
    restrictPublicBuckets: true,
});

// Create a VPC for our resources
const vpc = new aws.ec2.Vpc("demo-vpc", {
    cidrBlock: "10.0.0.0/16",
    enableDnsHostnames: true,
    enableDnsSupport: true,
    tags: {
        ...tags,
        Name: `${projectName}-${environment}-vpc`,
    },
});

// Create an Internet Gateway
const igw = new aws.ec2.InternetGateway("demo-igw", {
    vpcId: vpc.id,
    tags: {
        ...tags,
        Name: `${projectName}-${environment}-igw`,
    },
});

// Create a public subnet
const publicSubnet = new aws.ec2.Subnet("demo-public-subnet", {
    vpcId: vpc.id,
    cidrBlock: "10.0.1.0/24",
    availabilityZone: aws.getAvailabilityZones({}).then(azs => azs.names[0]),
    mapPublicIpOnLaunch: true,
    tags: {
        ...tags,
        Name: `${projectName}-${environment}-public-subnet`,
    },
});

// Create a route table for the public subnet
const publicRouteTable = new aws.ec2.RouteTable("demo-public-rt", {
    vpcId: vpc.id,
    routes: [
        {
            cidrBlock: "0.0.0.0/0",
            gatewayId: igw.id,
        },
    ],
    tags: {
        ...tags,
        Name: `${projectName}-${environment}-public-rt`,
    },
});

// Associate the route table with the public subnet
const publicRouteTableAssociation = new aws.ec2.RouteTableAssociation("demo-public-rta", {
    subnetId: publicSubnet.id,
    routeTableId: publicRouteTable.id,
});

// Create a security group for web servers
const webSecurityGroup = new aws.ec2.SecurityGroup("web-secgrp", {
    description: "Allow HTTP and HTTPS inbound traffic",
    vpcId: vpc.id,
    ingress: [
        {
            description: "HTTP",
            fromPort: 80,
            toPort: 80,
            protocol: "tcp",
            cidrBlocks: ["0.0.0.0/0"],
        },
        {
            description: "HTTPS",
            fromPort: 443,
            toPort: 443,
            protocol: "tcp",
            cidrBlocks: ["0.0.0.0/0"],
        },
        {
            description: "SSH",
            fromPort: 22,
            toPort: 22,
            protocol: "tcp",
            cidrBlocks: ["0.0.0.0/0"], // In production, restrict this to your IP
        },
    ],
    egress: [
        {
            fromPort: 0,
            toPort: 0,
            protocol: "-1",
            cidrBlocks: ["0.0.0.0/0"],
        },
    ],
    tags: {
        ...tags,
        Name: `${projectName}-${environment}-web-sg`,
    },
});

// Create an IAM role for EC2 instances
const ec2Role = new aws.iam.Role("ec2-role", {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [
            {
                Action: "sts:AssumeRole",
                Effect: "Allow",
                Principal: {
                    Service: "ec2.amazonaws.com",
                },
            },
        ],
    }),
    tags: {
        ...tags,
        Name: `${projectName}-${environment}-ec2-role`,
    },
});

// Create an IAM policy for S3 access
const s3Policy = new aws.iam.Policy("s3-policy", {
    description: "Policy for S3 bucket access",
    policy: pulumi.interpolate`{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "s3:GetObject",
                    "s3:PutObject",
                    "s3:DeleteObject",
                    "s3:ListBucket"
                ],
                "Resource": [
                    "${bucket.arn}",
                    "${bucket.arn}/*"
                ]
            }
        ]
    }`,
    tags: tags,
});

// Attach the policy to the role
const rolePolicyAttachment = new aws.iam.RolePolicyAttachment("role-policy-attachment", {
    role: ec2Role.name,
    policyArn: s3Policy.arn,
});

// Create an instance profile for the EC2 role
const instanceProfile = new aws.iam.InstanceProfile("instance-profile", {
    role: ec2Role.name,
    tags: tags,
});

// Export important values
export const bucketId = bucket.id;
export const bucketArn = bucket.arn;
export const vpcId = vpc.id;
export const publicSubnetId = publicSubnet.id;
export const securityGroupId = webSecurityGroup.id;
export const ec2RoleArn = ec2Role.arn;
export const instanceProfileArn = instanceProfile.arn;

// Export resource URLs for easy access
export const bucketUrl = pulumi.interpolate`https://s3.console.aws.amazon.com/s3/buckets/${bucket.id}`;
export const vpcUrl = pulumi.interpolate`https://console.aws.amazon.com/vpc/home?region=${aws.getRegion().then(r => r.name)}#vpcs:search=${vpc.id}`;
{{- end }}
