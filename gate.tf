############################
# Ingestion gate: reacts to DQ failures
#   1. writes gs://<artifacts>/gate/ingestion_paused.json  (Composer DAG short-circuits on it)
#   2. drains the streaming Dataflow job (backlog stays in the Pub/Sub subscription, retained 7d)
#   3. logs a CRITICAL "INGESTION_PAUSED" event -> Monitoring -> PagerDuty / Slack
# Resume: delete the flag object, then `terraform apply` (relaunches the drained job).
############################
data "archive_file" "gate" {
  type        = "zip"
  source_dir  = "${path.module}/functions/ingestion_gate"
  output_path = "${path.module}/.build/ingestion_gate.zip"
  excludes    = ["__pycache__", "tests"]
}

resource "google_storage_bucket_object" "gate_source" {
  name   = "functions/ingestion_gate/${data.archive_file.gate.output_md5}.zip"
  bucket = google_storage_bucket.buckets["artifacts"].name
  source = data.archive_file.gate.output_path
}

resource "google_cloudfunctions2_function" "gate" {
  name        = "${local.prefix}-ingestion-gate"
  location    = var.region
  description = "Pauses ingestion when the data-quality gate fails"
  labels      = local.labels

  build_config {
    runtime         = "python312"
    entry_point     = "handle"
    service_account = google_service_account.fn_build.id

    source {
      storage_source {
        bucket = google_storage_bucket.buckets["artifacts"].name
        object = google_storage_bucket_object.gate_source.name
      }
    }
  }

  service_config {
    available_memory               = "256M"
    timeout_seconds                = 120
    min_instance_count             = 0
    max_instance_count             = 2
    service_account_email          = google_service_account.gate.email
    ingress_settings               = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision = true

    environment_variables = {
      PROJECT_ID        = var.project_id
      DATAFLOW_REGION   = var.region
      DATAFLOW_JOB_NAME = local.dataflow_job_name
      ARTIFACTS_BUCKET  = google_storage_bucket.buckets["artifacts"].name
      GATE_FLAG_OBJECT  = local.gate_flag_object
      DEFAULT_ACTION    = var.gate_action
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.dq_failures.id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.eventarc.email
  }

  depends_on = [
    google_project_iam_member.project_roles,
    google_storage_bucket_iam_member.fn_build_on_artifacts,
  ]
}
