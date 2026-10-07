locals {
  required_apis = [
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "bigquerydatapolicy.googleapis.com",
    "bigquerystorage.googleapis.com",
    "bigqueryreservation.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "composer.googleapis.com",
    "compute.googleapis.com",
    "dataflow.googleapis.com",
    "eventarc.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)

  project                    = var.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

# Make sure Google-managed service agents exist before we grant them KMS roles.
resource "google_project_service_identity" "agents" {
  provider = google-beta
  for_each = toset([
    "pubsub.googleapis.com",
    "composer.googleapis.com",
    "dataflow.googleapis.com",
    "artifactregistry.googleapis.com",
  ])

  project = var.project_id
  service = each.value

  depends_on = [google_project_service.apis]
}
