locals {
  flex_template_path = coalesce(
    var.dataflow_flex_template_gcs_path,
    "gs://${google_storage_bucket.buckets["dataflow"].name}/templates/telemetry-stream.json"
  )
}

# Streaming Flex Template job.
#   Contract with the Beam pipeline (parameters below) is documented in README.md.
#   Draining (by the quality gate) leaves the job in a terminal state; the next `terraform apply`
#   sees it is gone and relaunches it = the "resume" path. Backlog is preserved in the subscription.
resource "google_dataflow_flex_template_job" "telemetry" {
  count    = var.deploy_dataflow_job ? 1 : 0
  provider = google-beta

  name                    = local.dataflow_job_name
  region                  = var.region
  container_spec_gcs_path = local.flex_template_path

  on_delete                    = "drain"
  skip_wait_on_job_termination = true

  service_account_email   = google_service_account.dataflow.email
  network                 = google_compute_network.this.name
  subnetwork              = "regions/${var.region}/subnetworks/${google_compute_subnetwork.data.name}"
  ip_configuration        = "WORKER_IP_PRIVATE"
  kms_key_name            = google_kms_crypto_key.keys["dataflow"].id
  machine_type            = var.dataflow_machine_type
  num_workers             = var.dataflow_min_workers
  max_workers             = var.dataflow_max_workers
  enable_streaming_engine = true
  autoscaling_algorithm   = "THROUGHPUT_BASED"
  staging_location        = "gs://${google_storage_bucket.buckets["dataflow"].name}/staging"
  temp_location           = "gs://${google_storage_bucket.buckets["dataflow"].name}/tmp"
  labels                  = local.labels

  parameters = {
    input_subscription       = google_pubsub_subscription.events_dataflow.id
    output_events_table      = "${var.project_id}:${google_bigquery_table.telemetry_events.dataset_id}.${google_bigquery_table.telemetry_events.table_id}"
    output_windowed_table    = "${var.project_id}:${google_bigquery_table.telemetry_windowed.dataset_id}.${google_bigquery_table.telemetry_windowed.table_id}"
    malformed_topic          = google_pubsub_topic.dead_letter["malformed"].id
    tumbling_window_seconds  = tostring(var.tumbling_window_seconds)
    sliding_window_seconds   = tostring(var.sliding_window_seconds)
    sliding_period_seconds   = tostring(var.sliding_window_period_seconds)
    allowed_lateness_seconds = tostring(var.allowed_lateness_seconds)
    iceberg_table            = var.enable_iceberg_table ? "${google_bigquery_table.telemetry_events_iceberg[0].dataset_id}.${google_bigquery_table.telemetry_events_iceberg[0].table_id}" : ""
  }

  depends_on = [
    google_project_iam_member.project_roles,
    google_pubsub_subscription_iam_member.dataflow_subscriber,
    google_pubsub_topic_iam_member.dataflow_publish_malformed,
    google_bigquery_dataset_iam_member.grants,
    google_storage_bucket_iam_member.dataflow_on_dataflow_bucket,
    google_compute_firewall.dataflow_internal,
    google_compute_router_nat.this,
    google_kms_crypto_key_iam_member.grants,
  ]
}
