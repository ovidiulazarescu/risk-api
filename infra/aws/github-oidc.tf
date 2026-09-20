data "aws_caller_identity" "current" {}

data "tls_certificate" "github_oidc" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_oidc.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:ovidiulazarescu/risk-api:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions_deployer" {
  name               = "github-actions-deployer"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

resource "aws_iam_role_policy" "deployer_apprunner" {
  name = "apprunner-deploy"
  role = aws_iam_role.github_actions_deployer.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["apprunner:*"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.apprunner_ecr_access.arn,
          aws_iam_role.apprunner_instance.arn
        ]
      }
    ]
  })
}

# Everything `terraform apply` in CI needs, scoped to this stack's resources
resource "aws_iam_role_policy" "deployer_terraform" {
  name = "terraform-apply"
  role = aws_iam_role.github_actions_deployer.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::tf-state-${data.aws_caller_identity.current.account_id}"
      },
      {
        # includes the .tflock object used by use_lockfile
        Sid      = "StateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::tf-state-${data.aws_caller_identity.current.account_id}/risk-api/*"
      },
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "EcrRepository"
        Effect   = "Allow"
        Action   = ["ecr:*"]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/risk-api"
      },
      {
        Sid    = "ManageStackIam"
        Effect = "Allow"
        Action = ["iam:*"]
        Resource = [
          aws_iam_role.apprunner_ecr_access.arn,
          aws_iam_role.apprunner_instance.arn,
          aws_iam_role.github_actions_deployer.arn,
          aws_iam_openid_connect_provider.github.arn
        ]
      },
      {
        Sid      = "AppRunnerServiceLinkedRole"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/apprunner.amazonaws.com/*"
        Condition = {
          StringEquals = { "iam:AWSServiceName" = "apprunner.amazonaws.com" }
        }
      }
    ]
  })
}
