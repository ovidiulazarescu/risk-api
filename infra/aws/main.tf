terraform {
  required_version = ">= 1.12.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  backend "s3" {
    bucket       = "tf-state-401323565803" # created by infra/aws-bootstrap
    key          = "risk-api/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true # S3 native locking, no DynamoDB table needed
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
}

# --- Container registry (equivalent of Artifact Registry) ---
resource "aws_ecr_repository" "risk_api" {
  name                 = "risk-api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- Role App Runner uses to PULL the image from ECR ---
data "aws_iam_policy_document" "apprunner_ecr_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["build.apprunner.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apprunner_ecr_access" {
  name               = "risk-api-apprunner-ecr-access"
  assume_role_policy = data.aws_iam_policy_document.apprunner_ecr_assume.json
}

resource "aws_iam_role_policy_attachment" "apprunner_ecr_access" {
  role       = aws_iam_role.apprunner_ecr_access.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
}

# --- Role the RUNNING service assumes (equivalent of the Cloud Run runtime SA) ---
data "aws_iam_policy_document" "apprunner_instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["tasks.apprunner.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apprunner_instance" {
  name               = "risk-api-apprunner-instance"
  assume_role_policy = data.aws_iam_policy_document.apprunner_instance_assume.json
}
# attach least-privilege policies here if the app needs to call other AWS services

resource "aws_apprunner_auto_scaling_configuration_version" "risk_api" {
  auto_scaling_configuration_name = "risk-api-scaling"
  min_size                        = 1 # App Runner has no true scale-to-zero, unlike Cloud Run
  max_size                        = 3
}

resource "aws_apprunner_service" "risk_api" {
  service_name = "risk-scoring-api"

  source_configuration {
    authentication_configuration {
      access_role_arn = aws_iam_role.apprunner_ecr_access.arn
    }
    image_repository {
      image_identifier      = "${aws_ecr_repository.risk_api.repository_url}:${var.image_tag}"
      image_repository_type = "ECR"
      image_configuration {
        port = "8080"
        runtime_environment_variables = {
          ENVIRONMENT = var.environment
        }
      }
    }
    auto_deployments_enabled = false
  }

  instance_configuration {
    cpu               = "1024"
    memory            = "2048"
    instance_role_arn = aws_iam_role.apprunner_instance.arn
  }

  auto_scaling_configuration_arn = aws_apprunner_auto_scaling_configuration_version.risk_api.arn

  health_check_configuration {
    protocol = "HTTP"
    path     = "/healthz"
  }
}

output "service_url" {
  value = aws_apprunner_service.risk_api.service_url
}
