terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.30.0, < 8.0.0"
    }
    # google-beta: google_dataflow_flex_template_job and google_project_service_identity
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.30.0, < 8.0.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Partial backend config. Initialise with:
  #   terraform init -backend-config="bucket=<state-bucket>" -backend-config="prefix=streaming-lakehouse/<env>"
  # The state bucket should be versioned, CMEK-encrypted and live in a separate admin project.
  backend "gcs" {}
}
