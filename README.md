# risk-api

A small FastAPI "risk scoring" service, provisioned identically on **Google Cloud (Cloud Run)** and
**AWS (App Runner)** by Terraform, and deployed by GitHub Actions using keyless OIDC auth on both
clouds. Built as a hands-on portfolio piece for GCP + Terraform + Python + GitHub Actions.

## Layout

```
app/                 FastAPI service (cloud-agnostic)
Dockerfile            container image, same on both clouds
infra/gcp/            Terraform: Cloud Run, service account, IAM
infra/aws/            Terraform: App Runner, ECR, IAM, GitHub OIDC provider
.github/workflows/    deploy-gcp.yml and deploy-aws.yml
```

## Run locally

```bash
docker build -t risk-api .
docker run -p 8080:8080 risk-api
curl -X POST localhost:8080/score \
  -H "Content-Type: application/json" \
  -d '{"credit_utilization": 0.3, "payment_history_score": 90, "debt_to_income": 0.25}'
```

## Example request

`POST /score` takes three fields and returns a score (300-850) and a risk band. Replace `$SERVICE_URL`
with `http://localhost:8080` locally, or with the `service_url` Terraform output once deployed
(e.g. `https://<id>.eu-central-1.awsapprunner.com`).

| Field | Type | Range |
|---|---|---|
| `credit_utilization` | float | 0.0 - 1.0 |
| `payment_history_score` | int | 0 - 100 |
| `debt_to_income` | float | 0.0 - 1.0 |

```bash
curl -X POST "$SERVICE_URL/score" \
  -H "Content-Type: application/json" \
  -d '{"credit_utilization": 0.1, "payment_history_score": 95, "debt_to_income": 0.15}'
```

Response:

```json
{"score": 615, "risk_band": "medium"}
```

Bands: `low` >= 700, `medium` >= 580, otherwise `high`. Health check: `GET $SERVICE_URL/healthz`.
Interactive API docs are served at `$SERVICE_URL/docs`.

## Deploy to GCP

1. `infra/gcp/main.tf`: set the GCS state bucket, and set up a Workload Identity Federation pool +
   provider (see [google-github-actions/auth](https://github.com/google-github-actions/auth) docs).
2. Fill in `PROJECT_ID`, the `workload_identity_provider`, and `service_account` in
   `.github/workflows/deploy-gcp.yml`.
3. Push to `main` — the workflow builds the image, pushes to Artifact Registry, and runs
   `terraform apply`.

## Deploy to AWS

Region: `eu-central-1`. Terraform state lives in an S3 bucket (`tf-state-<account-id>`) with S3 native
locking, so no DynamoDB table is needed. Requires Terraform >= 1.12.2 and admin AWS credentials for the
one-time setup below (`aws login`).

1. **State bucket** (once): `cd infra/aws-bootstrap && terraform init && terraform apply`. The bucket name
   is passed to `terraform init` via `-backend-config` (the backend block in `infra/aws/main.tf` has no
   hardcoded bucket). Set your account ID once in your shell:
   `export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)`.
2. **Bootstrap the stack** (once, from your machine): the GitHub OIDC provider and the
   `github-actions-deployer` role must exist before Actions can assume it, and App Runner needs an image
   in ECR before its service can be created.
   ```bash
   cd infra/aws
   terraform init -backend-config="bucket=tf-state-$ACCOUNT_ID"
   terraform apply \
     -target=aws_ecr_repository.risk_api \
     -target=aws_iam_role_policy.deployer_terraform \
     -target=aws_iam_role_policy.deployer_apprunner

   # push a first image
   aws ecr get-login-password --region eu-central-1 | \
     docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com
   docker build --platform linux/amd64 -t $ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com/risk-api:bootstrap .
   docker push $ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com/risk-api:bootstrap

   terraform apply -var="image_tag=bootstrap"
   ```
3. In the GitHub repo, add a repository **variable** (Settings > Secrets and variables > Actions >
   Variables) named `AWS_ACCOUNT_ID` with your account ID. The workflow uses it for the role ARN and
   the state bucket name. The repo name (`ovidiulazarescu/risk-api`) is set in `infra/aws/github-oidc.tf`;
   change it if you fork.
4. Push to `main`. The workflow builds the image, pushes it to ECR tagged with the commit SHA, and runs
   `terraform apply`. The service URL is the `service_url` Terraform output.

Notes: an account can have only one GitHub OIDC provider for `token.actions.githubusercontent.com`. If
yours already exists, import it (`terraform import aws_iam_openid_connect_provider.github <arn>`) before
applying. The `/score` endpoint is public and unauthenticated.

## Notes

- Both deploy workflows use OIDC federation — no long-lived cloud credentials stored in GitHub.
- App Runner has no true scale-to-zero (min instance count of 1); Cloud Run does. That's the one
  real cost/behavior difference between the two stacks.
- The `google_cloud_run_v2_service_iam_member` and App Runner instance role are both locked down by
  default.
