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

// Resource configuration flags from Helm values
const resources = config.getObject<any>("resources") || {
    s3: {
        bucket: { enabled: {{ .Values.resources.s3.bucket.enabled }} },
        publicAccessBlock: { enabled: {{ .Values.resources.s3.publicAccessBlock.enabled }} }
    },
    vpc: {
        vpc: { enabled: {{ .Values.resources.vpc.vpc.enabled }} },
        internetGateway: { enabled: {{ .Values.resources.vpc.internetGateway.enabled }} },
        publicSubnet: { enabled: {{ .Values.resources.vpc.publicSubnet.enabled }} },
        routeTable: { enabled: {{ .Values.resources.vpc.routeTable.enabled }} },
        routeTableAssociation: { enabled: {{ .Values.resources.vpc.routeTableAssociation.enabled }} }
    },
    security: {
        webSecurityGroup: { enabled: {{ .Values.resources.security.webSecurityGroup.enabled }} }
    },
    iam: {
        ec2Role: { enabled: {{ .Values.resources.iam.ec2Role.enabled }} },
        s3Policy: { enabled: {{ .Values.resources.iam.s3Policy.enabled }} },
        rolePolicyAttachment: { enabled: {{ .Values.resources.iam.rolePolicyAttachment.enabled }} },
        instanceProfile: { enabled: {{ .Values.resources.iam.instanceProfile.enabled }} }
    }
};

// Variables to hold resources for dependencies
let bucket: aws.s3.Bucket | undefined;
let vpc: aws.ec2.Vpc | undefined;
let igw: aws.ec2.InternetGateway | undefined;
let publicSubnet: aws.ec2.Subnet | undefined;
let publicRouteTable: aws.ec2.RouteTable | undefined;
let webSecurityGroup: aws.ec2.SecurityGroup | undefined;
let ec2Role: aws.iam.Role | undefined;
let s3Policy: aws.iam.Policy | undefined;

// Create S3 resources if enabled
if (resources.s3.bucket.enabled) {
    bucket = new aws.s3.Bucket("demo-bucket", {
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
}

// Block all public access to the S3 bucket (only if bucket exists)
let bucketPublicAccessBlock: aws.s3.BucketPublicAccessBlock | undefined;
if (resources.s3.publicAccessBlock.enabled && bucket) {
    bucketPublicAccessBlock = new aws.s3.BucketPublicAccessBlock("demo-bucket-pab", {
        bucket: bucket.id,
        blockPublicAcls: true,
        blockPublicPolicy: true,
        ignorePublicAcls: true,
        restrictPublicBuckets: true,
    });
}

// Create VPC and networking resources if enabled
if (resources.vpc.vpc.enabled) {
    vpc = new aws.ec2.Vpc("demo-vpc", {
        cidrBlock: "10.0.0.0/16",
        enableDnsHostnames: true,
        enableDnsSupport: true,
        tags: {
            ...tags,
            Name: `${projectName}-${environment}-vpc`,
        },
    });
}

// Create an Internet Gateway (only if VPC exists)
if (resources.vpc.internetGateway.enabled && vpc) {
    igw = new aws.ec2.InternetGateway("demo-igw", {
        vpcId: vpc.id,
        tags: {
            ...tags,
            Name: `${projectName}-${environment}-igw`,
        },
    });
}

// Create a public subnet (only if VPC exists)
if (resources.vpc.publicSubnet.enabled && vpc) {
    publicSubnet = new aws.ec2.Subnet("demo-public-subnet", {
        vpcId: vpc.id,
        cidrBlock: "10.0.1.0/24",
        availabilityZone: aws.getAvailabilityZones({}).then(azs => azs.names[0]),
        mapPublicIpOnLaunch: true,
        tags: {
            ...tags,
            Name: `${projectName}-${environment}-public-subnet`,
        },
    });
}

// Create a route table for the public subnet (only if VPC and IGW exist)
if (resources.vpc.routeTable.enabled && vpc && igw) {
    publicRouteTable = new aws.ec2.RouteTable("demo-public-rt", {
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
}

// Associate the route table with the public subnet (only if both exist)
let publicRouteTableAssociation: aws.ec2.RouteTableAssociation | undefined;
if (resources.vpc.routeTableAssociation.enabled && publicSubnet && publicRouteTable) {
    publicRouteTableAssociation = new aws.ec2.RouteTableAssociation("demo-public-rta", {
        subnetId: publicSubnet.id,
        routeTableId: publicRouteTable.id,
    });
}

// Create a security group for web servers (only if VPC exists)
if (resources.security.webSecurityGroup.enabled && vpc) {
    webSecurityGroup = new aws.ec2.SecurityGroup("web-secgrp", {
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
}

// Create IAM resources if enabled
if (resources.iam.ec2Role.enabled) {
    ec2Role = new aws.iam.Role("ec2-role", {
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
}

// Create an IAM policy for S3 access (only if S3 bucket exists)
if (resources.iam.s3Policy.enabled && bucket) {
    s3Policy = new aws.iam.Policy("s3-policy", {
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
}

// Attach the policy to the role (only if both exist)
let rolePolicyAttachment: aws.iam.RolePolicyAttachment | undefined;
if (resources.iam.rolePolicyAttachment.enabled && ec2Role && s3Policy) {
    rolePolicyAttachment = new aws.iam.RolePolicyAttachment("role-policy-attachment", {
        role: ec2Role.name,
        policyArn: s3Policy.arn,
    });
}

// Create an instance profile for the EC2 role (only if role exists)
let instanceProfile: aws.iam.InstanceProfile | undefined;
if (resources.iam.instanceProfile.enabled && ec2Role) {
    instanceProfile = new aws.iam.InstanceProfile("instance-profile", {
        role: ec2Role.name,
        tags: tags,
    });
}

// Export important values (only if resources exist)
export const bucketId = bucket?.id;
export const bucketArn = bucket?.arn;
export const vpcId = vpc?.id;
export const publicSubnetId = publicSubnet?.id;
export const securityGroupId = webSecurityGroup?.id;
export const ec2RoleArn = ec2Role?.arn;
export const instanceProfileArn = instanceProfile?.arn;

// Export resource URLs for easy access (only if resources exist)
export const bucketUrl = bucket ? pulumi.interpolate`https://s3.console.aws.amazon.com/s3/buckets/${bucket.id}` : undefined;
export const vpcUrl = vpc ? pulumi.interpolate`https://console.aws.amazon.com/vpc/home?region=${aws.getRegion().then(r => r.name)}#vpcs:search=${vpc.id}` : undefined;
{{- end }}
