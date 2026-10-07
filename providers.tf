provider "google" {
  project = var.project_id
  region  = var.region

  # Required for billing budgets / quota-project scoped APIs.
  user_project_override = true
  billing_project       = var.project_id

  default_labels = local.labels
}

provider "google-beta" {
  project = var.project_id
  region  = var.region

  user_project_override = true
  billing_project       = var.project_id

  default_labels = local.labels
}
