############################
# Datasets
#   raw       : landing tables written by Dataflow
#   curated   : dbt staging/marts
#   ops       : dead letters + data-quality results
#   lakehouse : BigLake managed Iceberg tables over GCS
############################
locals {
  datasets = {
    raw       = { description = "Streaming landing zone (Dataflow)", billing = "PHYSICAL" }
    curated   = { description = "dbt-modelled staging and marts", billing = "LOGICAL" }
    ops       = { description = "Dead letters and data-quality results", billing = "LOGICAL" }
    lakehouse = { description = "BigLake managed Iceberg tables", billing = "LOGICAL" }
  }
}

resource "google_bigquery_dataset" "this" {
  for_each = local.datasets

  dataset_id                      = "${replace(local.prefix, "-", "_")}_${each.key}"
  friendly_name                   = "${local.prefix} ${each.key}"
  description                     = each.value.description
  location                        = var.bq_location
  delete_contents_on_destroy      = !var.deletion_protection
  max_time_travel_hours           = 48
  storage_billing_model           = each.value.billing
  labels                          = local.labels
  default_table_expiration_ms     = null
  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.keys["bigquery"].id
  }

  lifecycle {
    precondition {
      condition     = var.bq_location == var.region
      error_message = "bq_location must equal region: the regional CMEKs and the BigLake/GCS bucket live in var.region."
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.grants]
}

############################
# Schemas
############################
locals {
  event_fields = [
    { name = "event_id", type = "STRING", mode = "REQUIRED" },
    { name = "event_type", type = "STRING", mode = "REQUIRED" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "source", type = "STRING", mode = "REQUIRED" },
    { name = "schema_version", type = "INT64", mode = "REQUIRED" },
    { name = "user_id", type = "STRING", mode = "NULLABLE" },
    { name = "session_id", type = "STRING", mode = "NULLABLE" },
    { name = "entity", type = "STRING", mode = "NULLABLE" },
    { name = "op", type = "STRING", mode = "NULLABLE" },
    { name = "payload", type = "JSON", mode = "NULLABLE" },
    { name = "ingest_timestamp", type = "TIMESTAMP", mode = "REQUIRED" },
  ]
}

############################
# Raw events: partitioned + clustered, partition filter enforced (runaway-query guard)
############################
resource "google_bigquery_table" "telemetry_events" {
  dataset_id          = google_bigquery_dataset.this["raw"].dataset_id
  table_id            = "telemetry_events"
  description         = "Validated streaming events (one row per event_id; dedup downstream)."
  deletion_protection = var.deletion_protection
  labels              = local.labels

  time_partitioning {
    type          = "DAY"
    field         = "event_timestamp"
    expiration_ms = var.raw_partition_expiration_days * 86400000
  }

  clustering = ["event_type", "user_id", "source"]

  require_partition_filter = true

  schema = jsonencode(local.event_fields)
}

resource "google_bigquery_table" "telemetry_windowed" {
  dataset_id          = google_bigquery_dataset.this["raw"].dataset_id
  table_id            = "telemetry_windowed"
  description         = "Tumbling + sliding window aggregates emitted by Dataflow."
  deletion_protection = var.deletion_protection
  labels              = local.labels

  time_partitioning {
    type          = "DAY"
    field         = "window_start"
    expiration_ms = var.raw_partition_expiration_days * 86400000
  }

  clustering               = ["window_type", "event_type"]
  require_partition_filter = true

  schema = jsonencode([
    { name = "window_type", type = "STRING", mode = "REQUIRED", description = "tumbling|sliding" },
    { name = "window_start", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "window_end", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "event_type", type = "STRING", mode = "REQUIRED" },
    { name = "event_count", type = "INT64", mode = "REQUIRED" },
    { name = "distinct_users_approx", type = "INT64", mode = "NULLABLE" },
    { name = "emitted_at", type = "TIMESTAMP", mode = "REQUIRED" },
  ])
}

############################
# Ops: dead letters + DQ results
############################
resource "google_bigquery_table" "dead_letter" {
  for_each = local.dead_letter_topics

  dataset_id          = google_bigquery_dataset.this["ops"].dataset_id
  table_id            = "dead_letter_${each.key}"
  description         = "Pub/Sub BigQuery-subscription sink for the ${each.key} dead-letter topic."
  deletion_protection = var.deletion_protection
  labels              = local.labels

  time_partitioning {
    type          = "DAY"
    field         = "publish_time"
    expiration_ms = var.dead_letter_expiration_days * 86400000
  }

  # Layout required by Pub/Sub write_metadata = true.
  schema = jsonencode([
    { name = "subscription_name", type = "STRING", mode = "NULLABLE" },
    { name = "message_id", type = "STRING", mode = "NULLABLE" },
    { name = "publish_time", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "data", type = "BYTES", mode = "NULLABLE" },
    { name = "attributes", type = "JSON", mode = "NULLABLE" },
  ])
}

resource "google_bigquery_table" "dq_results" {
  dataset_id          = google_bigquery_dataset.this["ops"].dataset_id
  table_id            = "dq_results"
  description         = "Per-run results from dbt tests and Great Expectations checkpoints."
  deletion_protection = var.deletion_protection
  labels              = local.labels

  time_partitioning {
    type  = "DAY"
    field = "run_timestamp"
  }

  clustering = ["suite", "status"]

  schema = jsonencode([
    { name = "run_timestamp", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "build_id", type = "STRING", mode = "NULLABLE" },
    { name = "suite", type = "STRING", mode = "REQUIRED", description = "dbt|great_expectations|soda" },
    { name = "check_name", type = "STRING", mode = "NULLABLE" },
    { name = "status", type = "STRING", mode = "REQUIRED", description = "pass|warn|fail" },
    { name = "details", type = "JSON", mode = "NULLABLE" },
  ])
}

############################
# BigLake managed Iceberg table (long-term, open-format archive of every event)
############################
resource "google_bigquery_connection" "biglake" {
  count = var.enable_iceberg_table ? 1 : 0

  connection_id = "${local.prefix}-biglake"
  location      = var.bq_location
  friendly_name = "BigLake -> GCS (${var.environment})"

  cloud_resource {}

  depends_on = [google_project_service.apis]
}

resource "google_bigquery_table" "telemetry_events_iceberg" {
  count = var.enable_iceberg_table ? 1 : 0

  dataset_id          = google_bigquery_dataset.this["lakehouse"].dataset_id
  table_id            = "telemetry_events_iceberg"
  description         = "Managed Iceberg (Parquet) copy of telemetry events; readable by Spark/Trino/Flink via the Iceberg catalog."
  deletion_protection = var.deletion_protection
  labels              = local.labels

  biglake_configuration {
    connection_id = google_bigquery_connection.biglake[0].name
    storage_uri   = "gs://${google_storage_bucket.buckets["lake"].name}/iceberg/telemetry_events"
    file_format   = "PARQUET"
    table_format  = "ICEBERG"
  }

  clustering = ["event_type", "user_id"]
  schema     = jsonencode(local.event_fields)

  depends_on = [google_storage_bucket_iam_member.biglake_on_lake]
}

############################
# Cost guardrails: optional autoscaling slot cap
############################
resource "google_bigquery_reservation" "this" {
  count = var.enable_bq_reservation ? 1 : 0

  name         = "${local.prefix}-standard"
  location     = var.bq_location
  edition      = "STANDARD"
  slot_capacity = 0
  ignore_idle_slots = false

  autoscale {
    max_slots = var.bq_max_autoscale_slots
  }

  depends_on = [google_project_service.apis]
}

resource "google_bigquery_reservation_assignment" "this" {
  count = var.enable_bq_reservation ? 1 : 0

  assignee    = "projects/${var.project_id}"
  job_type    = "QUERY"
  reservation = google_bigquery_reservation.this[0].id
}

resource "google_billing_budget" "this" {
  count = var.billing_account_id == null ? 0 : 1

  billing_account = var.billing_account_id
  display_name    = "${local.prefix}-monthly"

  budget_filter {
    projects        = ["projects/${local.project_number}"]
    calendar_period = "MONTH"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.8, 1.0]
    content {
      threshold_percent = threshold_rules.value
    }
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = local.alert_channels_warning
  }
}
