############################
# Schema registry + main topic
############################
resource "google_pubsub_schema" "event" {
  name       = "${local.prefix}-telemetry-event"
  type       = "AVRO"
  definition = coalesce(var.event_schema_definition, file("${path.module}/schemas/telemetry_event.avsc"))

  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "events" {
  name                       = "${local.prefix}-telemetry-events"
  kms_key_name               = google_kms_crypto_key.keys["pubsub"].id
  message_retention_duration = var.pubsub_message_retention
  labels                     = local.labels

  # Publishers sending non-conforming payloads are rejected at publish time -> schema drift never reaches Dataflow.
  schema_settings {
    schema   = google_pubsub_schema.event.id
    encoding = "JSON"
  }

  message_storage_policy {
    allowed_persistence_regions = [var.region]
  }

  depends_on = [google_kms_crypto_key_iam_member.grants]
}

############################
# Dead-letter topics
#   undeliverable : Pub/Sub gave up delivering to the Dataflow subscription
#   malformed     : Dataflow could not parse/validate/convert the record
############################
locals {
  dead_letter_topics = toset(["undeliverable", "malformed"])
}

resource "google_pubsub_topic" "dead_letter" {
  for_each = local.dead_letter_topics

  name                       = "${local.prefix}-telemetry-dlq-${each.key}"
  kms_key_name               = google_kms_crypto_key.keys["pubsub"].id
  message_retention_duration = var.pubsub_message_retention
  labels                     = local.labels

  depends_on = [google_kms_crypto_key_iam_member.grants]
}

# Durable, queryable sink for every dead letter (partitioned, auto-expiring).
resource "google_pubsub_subscription" "dead_letter_bq" {
  for_each = local.dead_letter_topics

  name   = "${local.prefix}-telemetry-dlq-${each.key}-bq"
  topic  = google_pubsub_topic.dead_letter[each.key].id
  labels = local.labels

  bigquery_config {
    table               = "${var.project_id}.${google_bigquery_table.dead_letter[each.key].dataset_id}.${google_bigquery_table.dead_letter[each.key].table_id}"
    write_metadata      = true
    drop_unknown_fields = false
  }

  expiration_policy {
    ttl = "" # never expire
  }

  depends_on = [google_bigquery_dataset_iam_member.pubsub_agent_ops]
}

# Pull subscription for replay tooling.
resource "google_pubsub_subscription" "dead_letter_replay" {
  for_each = local.dead_letter_topics

  name                       = "${local.prefix}-telemetry-dlq-${each.key}-replay"
  topic                      = google_pubsub_topic.dead_letter[each.key].id
  ack_deadline_seconds       = 60
  message_retention_duration = var.pubsub_message_retention
  labels                     = local.labels

  expiration_policy {
    ttl = ""
  }
}

############################
# Main subscription consumed by Dataflow
############################
resource "google_pubsub_subscription" "events_dataflow" {
  name                       = "${local.prefix}-telemetry-events-dataflow"
  topic                      = google_pubsub_topic.events.id
  ack_deadline_seconds       = 60
  message_retention_duration = var.pubsub_message_retention
  labels                     = local.labels

  expiration_policy {
    ttl = "" # a drained pipeline must not cause the subscription (and its backlog) to expire
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter["undeliverable"].id
    max_delivery_attempts = var.dlq_max_delivery_attempts
  }
}

############################
# Quality-gate signal topic (Cloud Build -> gate function)
############################
resource "google_pubsub_topic" "dq_failures" {
  name                       = "${local.prefix}-dq-failures"
  kms_key_name               = google_kms_crypto_key.keys["pubsub"].id
  message_retention_duration = "86400s"
  labels                     = local.labels

  depends_on = [google_kms_crypto_key_iam_member.grants]
}
