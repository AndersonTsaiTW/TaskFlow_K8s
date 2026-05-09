# ECR cross-account direct pull setup

This document records the minimum IAM and ECR policy setup for pulling a partner image directly from the partner ECR through GitHub Actions OIDC or Kubernetes runtime identity.

## Current decision

Web images are pulled directly from the partner ECR. We no longer copy/sync the partner web image into our own ECR as part of the main workflow.

- API image source: `485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/api:<tag>`
- Web image source: `692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:<tag>`
- Historical sync option: [archive/ecr-cross-account-sync-setup.md](archive/ecr-cross-account-sync-setup.md)

## 1) GitHub OIDC trust policy (our AWS role)

Use this as the trust relationship for the GitHub Actions ECR pull role in account `485104726319`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::485104726319:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<YOUR_GITHUB_ORG_OR_USER>/<YOUR_REPO>:*"
        }
      }
    }
  ]
}
```

Replace `<YOUR_GITHUB_ORG_OR_USER>/<YOUR_REPO>` with the real repository path.

## 2) IAM permissions policy for pull role (our AWS role)

Attach this to the GitHub Actions role that pulls images during CI.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrAuth",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PullFromPartnerRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:us-east-1:692735150780:repository/taskflow/web"
    }
  ]
}
```

Note: partner side still must allow your account/role in its ECR repository policy.

## 3) Partner ECR repository policy example (friend account)

Your friend applies this to repo `taskflow/web` in account `692735150780`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPullFromYourAccount",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::485104726319:root"
      },
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ]
    }
  ]
}
```

A stricter option is to set `Principal` to your specific role ARN instead of account root.

## 4) Runtime pull permissions for workloads

If your EKS nodes/pods need to pull private ECR images, attach read permissions to the runtime identity (node role or IRSA role):

- `ecr:GetAuthorizationToken`
- `ecr:BatchCheckLayerAvailability`
- `ecr:GetDownloadUrlForLayer`
- `ecr:BatchGetImage`

AWS managed policy `AmazonEC2ContainerRegistryReadOnly` can be used for pull-only access.

## 5) Expected test flow

1. Confirm the partner repo policy allows your CI/runtime identity to pull `taskflow/web`.
2. Login to the partner ECR and pull `692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:v1.0.6`.
3. Point Kubernetes Deployment or Helm values directly at the partner ECR URI.

PARTNER_REGION: us-east-1
PARTNER_REGISTRY: 692735150780.dkr.ecr.us-east-1.amazonaws.com
PARTNER_REPOSITORY: taskflow/web

MY_REGION: ca-central-1
MY_REGISTRY: 485104726319.dkr.ecr.ca-central-1.amazonaws.com
MY_REPOSITORY: taskflow/api

## Deprecated option: sync partner web image to our ECR

The previous design copied `692735150780.dkr.ecr.us-east-1.amazonaws.com/taskflow/web:<tag>` into `485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/web:<tag>`.

That design is not the active path anymore, but the original IAM policy and test flow are preserved in [archive/ecr-cross-account-sync-setup.md](archive/ecr-cross-account-sync-setup.md) in case direct partner ECR pulls become unreliable or unavailable.
