data "google_project" "this" {
  project_id = var.project_id
}

locals {
  prefix         = "${var.name_prefix}-${var.environment}"
  project_number = data.google_project.this.number

  labels = merge(
    {
      app         = var.name_prefix
      environment = var.environment
      managed_by  = "terraform"
    },
    var.extra_labels
  )

  # Google-managed service agents (CMEK grants, Pub/Sub dead-lettering, etc.)
  agents = {
    pubsub   = "serviceAccount:service-${local.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
    bigquery = "serviceAccount:bq-${local.project_number}@bigquery-encryption.iam.gserviceaccount.com"
    gcs      = "serviceAccount:service-${local.project_number}@gs-project-accounts.iam.gserviceaccount.com"
    composer = "serviceAccount:service-${local.project_number}@cloudcomposer-accounts.iam.gserviceaccount.com"
    dataflow = "serviceAccount:service-${local.project_number}@dataflow-service-producer-prod.iam.gserviceaccount.com"
    compute  = "serviceAccount:service-${local.project_number}@compute-system.iam.gserviceaccount.com"
    artifact = "serviceAccount:service-${local.project_number}@gcp-sa-artifactregistry.iam.gserviceaccount.com"
  }

  # Bucket names (globally unique -> project id prefix)
  buckets = {
    lake      = "${var.project_id}-${local.prefix}-lake"
    dataflow  = "${var.project_id}-${local.prefix}-dataflow"
    artifacts = "${var.project_id}-${local.prefix}-artifacts"
  }

  dataflow_job_name = "${local.prefix}-telemetry-stream"
  gate_flag_object  = "gate/ingestion_paused.json"

  alert_channels_critical = compact(concat(
    [for c in google_monitoring_notification_channel.pagerduty : c.id],
    [for c in google_monitoring_notification_channel.slack : c.id],
    [for c in google_monitoring_notification_channel.email : c.id],
  ))
  alert_channels_warning = compact(concat(
    [for c in google_monitoring_notification_channel.slack : c.id],
    [for c in google_monitoring_notification_channel.email : c.id],
  ))
}
