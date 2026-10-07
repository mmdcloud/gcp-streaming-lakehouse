output "pubsub_topic" {
  description = "Publish telemetry here (Avro schema enforced, JSON encoding)."
  value       = google_pubsub_topic.events.id
}

output "pubsub_subscription_dataflow" {
  value = google_pubsub_subscription.events_dataflow.id
}

output "dead_letter_topics" {
  value = { for k, t in google_pubsub_topic.dead_letter : k => t.id }
}

output "datasets" {
  value = { for k, d in google_bigquery_dataset.this : k => d.dataset_id }
}

output "raw_events_table" {
  value = "${var.project_id}.${google_bigquery_table.telemetry_events.dataset_id}.${google_bigquery_table.telemetry_events.table_id}"
}

output "iceberg_table" {
  value = var.enable_iceberg_table ? "${var.project_id}.${google_bigquery_table.telemetry_events_iceberg[0].dataset_id}.${google_bigquery_table.telemetry_events_iceberg[0].table_id}" : null
}

output "buckets" {
  value = { for k, b in google_storage_bucket.buckets : k => b.name }
}

output "artifact_registry_repo" {
  description = "Push the Flex Template image and the dbt/GE runner image here."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "flex_template_gcs_path" {
  description = "Where the Flex Template spec must be published before setting deploy_dataflow_job = true."
  value       = local.flex_template_path
}

output "composer_airflow_uri" {
  value = google_composer_environment.this.config[0].airflow_uri
}

output "gate_flag_uri" {
  description = "While this object exists, ingestion is considered paused. Delete it to resume."
  value       = "gs://${google_storage_bucket.buckets["artifacts"].name}/${local.gate_flag_object}"
}

output "service_accounts" {
  value = {
    dataflow   = google_service_account.dataflow.email
    composer   = google_service_account.composer.email
    cloudbuild = google_service_account.cloudbuild.email
    gate       = google_service_account.gate.email
  }
}
