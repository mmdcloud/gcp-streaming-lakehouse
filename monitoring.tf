############################
# Notification channels
############################
resource "google_monitoring_notification_channel" "email" {
  for_each = toset(var.alert_emails)

  display_name = "${local.prefix} email ${each.value}"
  type         = "email"
  labels       = { email_address = each.value }

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_notification_channel" "slack" {
  count = var.slack_channel_name != null && var.slack_auth_token != null ? 1 : 0

  display_name = "${local.prefix} Slack ${var.slack_channel_name}"
  type         = "slack"
  labels       = { channel_name = var.slack_channel_name }

  sensitive_labels {
    auth_token = var.slack_auth_token
  }

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_notification_channel" "pagerduty" {
  count = var.pagerduty_service_key != null ? 1 : 0

  display_name = "${local.prefix} PagerDuty"
  type         = "pagerduty"

  sensitive_labels {
    service_key = var.pagerduty_service_key
  }

  depends_on = [google_project_service.apis]
}

############################
# Metric alerts (SLO-style: freshness, lag, backlog, dead letters)
############################
locals {
  metric_alerts = merge(
    {
      pubsub_backlog_age = {
        display   = "Pub/Sub backlog age high"
        filter    = "resource.type=\"pubsub_subscription\" AND resource.labels.subscription_id=\"${google_pubsub_subscription.events_dataflow.name}\" AND metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\""
        threshold = var.alert_backlog_age_seconds
        duration  = "300s"
        aligner   = "ALIGN_MAX"
        critical  = true
        doc       = "Oldest unacked message exceeds ${var.alert_backlog_age_seconds}s. The pipeline is stalled, drained by the quality gate, or under-provisioned."
      }
      dataflow_system_lag = {
        display   = "Dataflow system lag high"
        filter    = "resource.type=\"dataflow_job\" AND resource.labels.job_name=\"${local.dataflow_job_name}\" AND metric.type=\"dataflow.googleapis.com/job/system_lag\""
        threshold = var.alert_system_lag_seconds
        duration  = "300s"
        aligner   = "ALIGN_MAX"
        critical  = false
        doc       = "System lag above ${var.alert_system_lag_seconds}s: autoscaling ceiling (max_workers) reached or a hot key."
      }
      dataflow_watermark_age = {
        display   = "Dataflow data watermark stale"
        filter    = "resource.type=\"dataflow_job\" AND resource.labels.job_name=\"${local.dataflow_job_name}\" AND metric.type=\"dataflow.googleapis.com/job/data_watermark_age\""
        threshold = 600
        duration  = "300s"
        aligner   = "ALIGN_MAX"
        critical  = true
        doc       = "Data freshness SLO breach: watermark older than 10 minutes."
      }
      dataflow_job_failed = {
        display   = "Dataflow job failed"
        filter    = "resource.type=\"dataflow_job\" AND resource.labels.job_name=\"${local.dataflow_job_name}\" AND metric.type=\"dataflow.googleapis.com/job/is_failed\""
        threshold = 0
        duration  = "0s"
        aligner   = "ALIGN_COUNT_TRUE"
        critical  = true
        doc       = "Streaming job entered a failed state. Check Dataflow logs; relaunch with terraform apply."
      }
    },
    {
      for k in local.dead_letter_topics : "dlq_${k}_backlog" => {
        display   = "Dead-letter backlog (${k})"
        filter    = "resource.type=\"pubsub_subscription\" AND resource.labels.subscription_id=\"${google_pubsub_subscription.dead_letter_replay[k].name}\" AND metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\""
        threshold = var.alert_dlq_messages_threshold
        duration  = "300s"
        aligner   = "ALIGN_MAX"
        critical  = false
        doc       = "More than ${var.alert_dlq_messages_threshold} dead letters (${k}). Likely schema drift or a bad producer; inspect ops.dead_letter_${k}."
      }
    }
  )

  log_alerts = {
    ingestion_paused = {
      display  = "INGESTION PAUSED by data-quality gate"
      filter   = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${google_cloudfunctions2_function.gate.name}\" AND jsonPayload.event=\"INGESTION_PAUSED\""
      critical = true
      doc      = "dbt tests or Great Expectations failed. The gate flag is set and the Dataflow job was drained (backlog preserved in Pub/Sub). Fix the data, delete gs://${local.buckets["artifacts"]}/${local.gate_flag_object}, then terraform apply to relaunch."
    }
    gate_error = {
      display  = "Ingestion gate function ERROR"
      filter   = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"${google_cloudfunctions2_function.gate.name}\" AND severity>=ERROR AND NOT jsonPayload.event=\"INGESTION_PAUSED\""
      critical = true
      doc      = "The gate function failed while handling a DQ failure; ingestion may NOT have been paused. Act manually."
    }
  }
}

resource "google_monitoring_alert_policy" "metric" {
  for_each = local.metric_alerts

  display_name = "[${var.environment}] ${each.value.display}"
  combiner     = "OR"
  severity     = each.value.critical ? "CRITICAL" : "WARNING"
  enabled      = true
  user_labels  = local.labels

  conditions {
    display_name = each.value.display

    condition_threshold {
      filter          = each.value.filter
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.threshold
      duration        = each.value.duration

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = each.value.aligner
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = each.value.critical ? local.alert_channels_critical : local.alert_channels_warning

  documentation {
    mime_type = "text/markdown"
    content   = each.value.doc
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "log" {
  for_each = local.log_alerts

  display_name = "[${var.environment}] ${each.value.display}"
  combiner     = "OR"
  severity     = each.value.critical ? "CRITICAL" : "WARNING"
  enabled      = true
  user_labels  = local.labels

  conditions {
    display_name = each.value.display

    condition_matched_log {
      filter = each.value.filter
    }
  }

  notification_channels = each.value.critical ? local.alert_channels_critical : local.alert_channels_warning

  documentation {
    mime_type = "text/markdown"
    content   = each.value.doc
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "86400s"
  }
}
