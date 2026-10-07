############################
# Core
############################
variable "project_id" {
  description = "GCP project that hosts the platform."
  type        = string
}

variable "region" {
  description = "Primary region for Dataflow, Composer, GCS, KMS, BigQuery (regional)."
  type        = string
  default     = "asia-south1"
}

variable "bq_location" {
  description = "BigQuery dataset location. Must match the GCS bucket / BigLake connection location for Iceberg tables."
  type        = string
  default     = "asia-south1"
}

variable "environment" {
  description = "Environment name (dev|stg|prod)."
  type        = string
  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment must be one of dev, stg, prod."
  }
}

variable "name_prefix" {
  description = "Short prefix for resource names."
  type        = string
  default     = "tlm"
  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,8}$", var.name_prefix))
    error_message = "name_prefix must be 2-9 chars, lowercase alphanumeric, starting with a letter."
  }
}

variable "extra_labels" {
  description = "Additional labels applied to all supported resources."
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Protect stateful resources (BigQuery tables, KMS keys' prevent_destroy is always on). Set false only for throwaway envs."
  type        = bool
  default     = true
}

############################
# Network
############################
variable "subnet_cidr" {
  description = "Primary CIDR for the data-platform subnet (Dataflow workers + Composer 3)."
  type        = string
  default     = "10.10.0.0/20"
}

############################
# Pub/Sub
############################
variable "event_schema_definition" {
  description = "Avro schema (JSON string) enforced on the telemetry topic. Leave null to use the bundled default."
  type        = string
  default     = null
}

variable "pubsub_message_retention" {
  description = "Topic and subscription message retention. Bigger = more safety margin when the pipeline is drained by the quality gate."
  type        = string
  default     = "604800s" # 7 days
}

variable "dlq_max_delivery_attempts" {
  description = "Delivery attempts before Pub/Sub forwards a message to the subscription-level dead-letter topic (5-100)."
  type        = number
  default     = 5
}

############################
# Dataflow
############################
variable "deploy_dataflow_job" {
  description = "Launch the streaming Flex Template job. Requires the template spec + image to exist (see README)."
  type        = bool
  default     = false
}

variable "dataflow_flex_template_gcs_path" {
  description = "gs:// path to the Flex Template spec JSON. Null -> gs://<dataflow bucket>/templates/telemetry-stream.json."
  type        = string
  default     = null
}

variable "dataflow_machine_type" {
  type    = string
  default = "n2-standard-2"
}

variable "dataflow_min_workers" {
  type    = number
  default = 1
}

variable "dataflow_max_workers" {
  description = "Hard autoscaling ceiling = hard cost ceiling for the streaming job."
  type        = number
  default     = 10
}

variable "tumbling_window_seconds" {
  type    = number
  default = 60
}

variable "sliding_window_seconds" {
  type    = number
  default = 300
}

variable "sliding_window_period_seconds" {
  type    = number
  default = 60
}

variable "allowed_lateness_seconds" {
  type    = number
  default = 120
}

############################
# BigQuery / cost controls
############################
variable "raw_partition_expiration_days" {
  description = "Partition expiry for raw events (lakehouse Iceberg copy is the long-term archive)."
  type        = number
  default     = 90
}

variable "dead_letter_expiration_days" {
  type    = number
  default = 30
}

variable "enable_iceberg_table" {
  description = "Create the BigLake managed Iceberg table on GCS."
  type        = bool
  default     = true
}

variable "enable_bq_reservation" {
  description = "Create an autoscaling BigQuery Standard-edition reservation (capped slots => capped spend) instead of on-demand pricing."
  type        = bool
  default     = false
}

variable "bq_max_autoscale_slots" {
  description = "Autoscale ceiling (multiple of 50) when enable_bq_reservation = true."
  type        = number
  default     = 100
}

variable "dbt_max_bytes_billed" {
  description = "Per-query ceiling injected as DBT_MAX_BYTES_BILLED into Cloud Build / Composer runs (default 100 GiB)."
  type        = number
  default     = 107374182400
}

variable "billing_account_id" {
  description = "Billing account ID. When set, a monthly budget with alerts is created."
  type        = string
  default     = null
}

variable "monthly_budget_amount" {
  description = "Monthly budget in USD (used only if billing_account_id is set)."
  type        = number
  default     = 500
}

############################
# Orchestration / data quality
############################
variable "composer_image_version" {
  description = "Composer 3 image. Verify the current one: gcloud composer environments list-upgrades / gcloud composer image-versions list."
  type        = string
  default     = "composer-3-airflow-2.10.5"
}

variable "composer_environment_size" {
  type    = string
  default = "ENVIRONMENT_SIZE_SMALL"
}

variable "composer_pypi_packages" {
  description = "Extra PyPI packages for Airflow (name => version spec)."
  type        = map(string)
  default = {
    "apache-airflow-providers-google" = ">=10.20.0"
  }
}

variable "dq_runner_image" {
  description = "Container image with dbt-bigquery + great_expectations (+ soda optional). Build it yourself and push to the Artifact Registry repo this module creates."
  type        = string
}

variable "gcloud_image" {
  type    = string
  default = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
}

variable "source_repo_uri" {
  description = "GitHub repo URI holding dbt/ and data_quality/ (e.g. https://github.com/org/repo). Needs the Cloud Build GitHub app installed."
  type        = string
}

variable "source_repo_ref" {
  type    = string
  default = "refs/heads/main"
}

variable "gate_action" {
  description = "What the gate does on DQ failure: 'drain' (flag + drain Dataflow job) or 'flag_only' (flag only; Composer pauses downstream)."
  type        = string
  default     = "drain"
  validation {
    condition     = contains(["drain", "flag_only"], var.gate_action)
    error_message = "gate_action must be 'drain' or 'flag_only'."
  }
}

variable "dq_schedule" {
  description = "Airflow cron for the quality-gate + transform DAG."
  type        = string
  default     = "*/15 * * * *"
}

############################
# Alerting
############################
variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "slack_channel_name" {
  description = "Slack channel (e.g. #data-alerts). Null disables the Slack channel."
  type        = string
  default     = null
}

variable "slack_auth_token" {
  description = "Slack OAuth token for Cloud Monitoring. Sensitive; lands in (encrypted) state - inject via TF_VAR_slack_auth_token."
  type        = string
  default     = null
  sensitive   = true
}

variable "pagerduty_service_key" {
  description = "PagerDuty Events API v2 integration key. Null disables PagerDuty. Inject via TF_VAR_pagerduty_service_key."
  type        = string
  default     = null
  sensitive   = true
}

variable "alert_backlog_age_seconds" {
  type    = number
  default = 300
}

variable "alert_system_lag_seconds" {
  type    = number
  default = 120
}

variable "alert_dlq_messages_threshold" {
  type    = number
  default = 100
}
