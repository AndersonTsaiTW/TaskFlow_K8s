# ECR cross-account sync setup

This document records the minimum IAM and ECR policy setup for syncing a partner image to our ECR through GitHub Actions OIDC.

## 1) GitHub OIDC trust policy (our AWS role)

Use this as the trust relationship for role `github-actions-ecr-push-role` in account `485104726319`.

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

## 2) IAM permissions policy for sync role (our AWS role)

Attach this to role `github-actions-ecr-push-role`.

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
    },
    {
      "Sid": "PushToOurRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:ListImages",
        "ecr:PutImage",
        "ecr:UploadLayerPart"
      ],
      "Resource": "arn:aws:ecr:ca-central-1:485104726319:repository/taskflow/web"
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

1. Run workflow `Sync partner web image to our ECR` with `partner_image_tag=v1.0.6`.
2. Verify image exists in our ECR: `485104726319.dkr.ecr.ca-central-1.amazonaws.com/taskflow/web:v1.0.6`.
3. Update Kubernetes Deployment image to our ECR URI.
