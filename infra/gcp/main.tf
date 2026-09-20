terraform {
  required_version = ">= 1.7.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  backend "gcs" {
    bucket = "your-terraform-state-bucket"
    prefix = "risk-api/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_service_account" "run_sa" {
  account_id   = "risk-api-runner"
  display_name = "Cloud Run runtime SA for risk-api"
}

resource "google_cloud_run_v2_service" "risk_api" {
  name     = "risk-scoring-api"
  location = var.region

  template {
    service_account = google_service_account.run_sa.email

    containers {
      image = "us-docker.pkg.dev/${var.project_id}/risk-api/app:${var.image_tag}"
      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

# Locked down on purpose - tighten further for anything resembling a real financial workload
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  name     = google_cloud_run_v2_service.risk_api.name
  location = google_cloud_run_v2_service.risk_api.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.run_sa.email}"
}

output "service_url" {
  value = google_cloud_run_v2_service.risk_api.uri
}
