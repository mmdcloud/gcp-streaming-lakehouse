############################
# Workload identities (one per component, least privilege)
############################
resource "google_service_account" "dataflow" {
  account_id   = "${local.prefix}-dataflow"
  display_name = "Dataflow streaming worker (${var.environment})"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "composer" {
  account_id   = "${local.prefix}-composer"
  display_name = "Cloud Composer environment (${var.environment})"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "cloudbuild" {
  account_id   = "${local.prefix}-cloudbuild"
  display_name = "Cloud Build data-quality runner (${var.environment})"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "gate" {
  account_id   = "${local.prefix}-gate-fn"
  display_name = "Ingestion gate function (${var.environment})"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "fn_build" {
  account_id   = "${local.prefix}-fn-build"
  display_name = "Gate function build identity (${var.environment})"

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "eventarc" {
  account_id   = "${local.prefix}-eventarc"
  display_name = "Eventarc trigger identity for gate function (${var.environment})"

  depends_on = [google_project_service.apis]
}

############################
# Project-level roles (only what cannot be scoped to a resource)
############################
locals {
  project_roles = {
    dataflow = {
      sa    = google_service_account.dataflow.email
      roles = ["roles/dataflow.worker", "roles/bigquery.jobUser", "roles/monitoring.metricWriter", "roles/logging.logWriter"]
    }
    composer = {
      sa    = google_service_account.composer.email
      roles = ["roles/composer.worker", "roles/bigquery.jobUser", "roles/cloudbuild.builds.editor", "roles/dataflow.viewer"]
    }
    cloudbuild = {
      sa    = google_service_account.cloudbuild.email
      roles = ["roles/logging.logWriter", "roles/bigquery.jobUser", "roles/artifactregistry.writer"]
    }
    gate = {
      sa    = google_service_account.gate.email
      roles = ["roles/dataflow.developer", "roles/logging.logWriter"]
    }
    eventarc = {
      sa    = google_service_account.eventarc.email
      roles = ["roles/eventarc.eventReceiver"]
    }
    fn_build = {
      sa    = google_service_account.fn_build.email
      roles = ["roles/cloudbuild.builds.builder"]
    }
  }

  project_role_pairs = merge([
    for k, v in local.project_roles : {
      for r in v.roles : "${k}|${r}" => { sa = v.sa, role = r }
    }
  ]...)
}

resource "google_project_iam_member" "project_roles" {
  for_each = local.project_role_pairs

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${each.value.sa}"
}

# Composer 3 with a user-managed SA needs the service agent extension role.
resource "google_project_iam_member" "composer_agent_ext" {
  project = var.project_id
  role    = "roles/composer.ServiceAgentV2Ext"
  member  = local.agents.composer

  depends_on = [google_project_service_identity.agents]
}

# Composer launches Cloud Build triggers that run as the cloudbuild SA.
resource "google_service_account_iam_member" "composer_acts_as_cloudbuild" {
  service_account_id = google_service_account.cloudbuild.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.composer.email}"
}

############################
# Resource-scoped roles
############################
# --- GCS ---
resource "google_storage_bucket_iam_member" "dataflow_on_dataflow_bucket" {
  bucket = google_storage_bucket.buckets["dataflow"].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_storage_bucket_iam_member" "dataflow_on_lake" {
  bucket = google_storage_bucket.buckets["lake"].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_storage_bucket_iam_member" "biglake_on_lake" {
  count = var.enable_iceberg_table ? 1 : 0

  bucket = google_storage_bucket.buckets["lake"].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_bigquery_connection.biglake[0].cloud_resource[0].service_account_id}"
}

resource "google_storage_bucket_iam_member" "cloudbuild_on_artifacts" {
  bucket = google_storage_bucket.buckets["artifacts"].name
  role   = "roles/storage.objectAdmin" # writes GE data docs + reads function source
  member = "serviceAccount:${google_service_account.cloudbuild.email}"
}

resource "google_storage_bucket_iam_member" "gate_on_artifacts" {
  bucket = google_storage_bucket.buckets["artifacts"].name
  role   = "roles/storage.objectAdmin" # writes/clears the gate flag
  member = "serviceAccount:${google_service_account.gate.email}"
}

resource "google_storage_bucket_iam_member" "fn_build_on_artifacts" {
  bucket = google_storage_bucket.buckets["artifacts"].name
  role   = "roles/storage.objectViewer" # reads the function source zip
  member = "serviceAccount:${google_service_account.fn_build.email}"
}

resource "google_storage_bucket_iam_member" "composer_on_artifacts" {
  bucket = google_storage_bucket.buckets["artifacts"].name
  role   = "roles/storage.objectViewer" # reads the gate flag
  member = "serviceAccount:${google_service_account.composer.email}"
}

# --- Pub/Sub ---
resource "google_pubsub_subscription_iam_member" "dataflow_subscriber" {
  subscription = google_pubsub_subscription.events_dataflow.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_pubsub_subscription_iam_member" "dataflow_viewer" {
  subscription = google_pubsub_subscription.events_dataflow.name
  role         = "roles/pubsub.viewer"
  member       = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_pubsub_topic_iam_member" "dataflow_publish_malformed" {
  topic  = google_pubsub_topic.dead_letter["malformed"].name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.dataflow.email}"
}

resource "google_pubsub_topic_iam_member" "cloudbuild_publish_dq_failures" {
  topic  = google_pubsub_topic.dq_failures.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.cloudbuild.email}"
}

# Pub/Sub service agent: forward undeliverable messages to the DLQ topic.
resource "google_pubsub_topic_iam_member" "agent_publish_dlq" {
  topic  = google_pubsub_topic.dead_letter["undeliverable"].name
  role   = "roles/pubsub.publisher"
  member = local.agents.pubsub

  depends_on = [google_project_service_identity.agents]
}

resource "google_pubsub_subscription_iam_member" "agent_ack_source" {
  subscription = google_pubsub_subscription.events_dataflow.name
  role         = "roles/pubsub.subscriber"
  member       = local.agents.pubsub

  depends_on = [google_project_service_identity.agents]
}

# --- BigQuery (dataset scoped) ---
locals {
  dataset_grants = {
    "dataflow|raw|editor"      = { ds = "raw", role = "roles/bigquery.dataEditor", sa = google_service_account.dataflow.email }
    "dataflow|ops|editor"      = { ds = "ops", role = "roles/bigquery.dataEditor", sa = google_service_account.dataflow.email }
    "dataflow|lake|editor"     = { ds = "lakehouse", role = "roles/bigquery.dataEditor", sa = google_service_account.dataflow.email }
    "cloudbuild|raw|viewer"    = { ds = "raw", role = "roles/bigquery.dataViewer", sa = google_service_account.cloudbuild.email }
    "cloudbuild|curated|edit"  = { ds = "curated", role = "roles/bigquery.dataEditor", sa = google_service_account.cloudbuild.email }
    "cloudbuild|ops|editor"    = { ds = "ops", role = "roles/bigquery.dataEditor", sa = google_service_account.cloudbuild.email }
    "cloudbuild|lake|viewer"   = { ds = "lakehouse", role = "roles/bigquery.dataViewer", sa = google_service_account.cloudbuild.email }
    "composer|curated|viewer"  = { ds = "curated", role = "roles/bigquery.dataViewer", sa = google_service_account.composer.email }
    "composer|ops|viewer"      = { ds = "ops", role = "roles/bigquery.dataViewer", sa = google_service_account.composer.email }
  }
}

resource "google_bigquery_dataset_iam_member" "grants" {
  for_each = local.dataset_grants

  dataset_id = google_bigquery_dataset.this[each.value.ds].dataset_id
  role       = each.value.role
  member     = "serviceAccount:${each.value.sa}"
}

# Pub/Sub BigQuery subscriptions (DLQ sinks) write as the Pub/Sub service agent.
resource "google_bigquery_dataset_iam_member" "pubsub_agent_ops" {
  dataset_id = google_bigquery_dataset.this["ops"].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = local.agents.pubsub

  depends_on = [google_project_service_identity.agents]
}

# --- Artifact Registry ---
resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = {
    dataflow   = google_service_account.dataflow.email
    cloudbuild = google_service_account.cloudbuild.email
    composer   = google_service_account.composer.email
  }

  repository = google_artifact_registry_repository.images.name
  location   = var.region
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${each.value}"
}

# --- Cloud Run (gate function) invoked by Eventarc ---
resource "google_cloud_run_v2_service_iam_member" "eventarc_invoker" {
  name     = google_cloudfunctions2_function.gate.service_config[0].service
  location = var.region
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.eventarc.email}"
}
