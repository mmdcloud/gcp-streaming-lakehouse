resource "google_composer_environment" "this" {
  name   = "${local.prefix}-composer"
  region = var.region
  labels = local.labels

  config {
    environment_size           = var.composer_environment_size
    enable_private_environment = true
    resilience_mode            = var.environment == "prod" ? "HIGH_RESILIENCE" : "STANDARD_RESILIENCE"

    software_config {
      image_version = var.composer_image_version
      pypi_packages = var.composer_pypi_packages

      airflow_config_overrides = {
        "core-dags_are_paused_at_creation" = "True"
        "core-default_task_retries"        = "1"
        "scheduler-catchup_by_default"     = "False"
      }

      env_variables = {
        PROJECT_ID       = var.project_id
        REGION           = var.region
        ARTIFACTS_BUCKET = google_storage_bucket.buckets["artifacts"].name
        GATE_FLAG_OBJECT = local.gate_flag_object
        DQ_TRIGGER_ID    = google_cloudbuild_trigger.dq_gate.trigger_id
        DBT_TRIGGER_ID   = google_cloudbuild_trigger.dbt_run.trigger_id
        SOURCE_BRANCH    = trimprefix(var.source_repo_ref, "refs/heads/")
        DQ_SCHEDULE      = var.dq_schedule
      }
    }

    node_config {
      network         = google_compute_network.this.id
      subnetwork      = google_compute_subnetwork.data.id
      service_account = google_service_account.composer.email
    }

    encryption_config {
      kms_key_name = google_kms_crypto_key.keys["composer"].id
    }

    workloads_config {
      worker {
        cpu        = 1
        memory_gb  = 4
        storage_gb = 10
        min_count  = 1
        max_count  = 3
      }
    }

    maintenance_window {
      # Composer requires >= 12h per week: Sun 21:00Z -> Mon 09:00Z
      start_time = "2026-01-04T21:00:00Z"
      end_time   = "2026-01-05T09:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SU"
    }
  }

  depends_on = [
    google_project_iam_member.composer_agent_ext,
    google_project_iam_member.project_roles,
    google_kms_crypto_key_iam_member.grants,
    google_compute_router_nat.this,
  ]
}

locals {
  composer_dag_bucket = regex("^gs://([^/]+)/", google_composer_environment.this.config[0].dag_gcs_prefix)[0]
}

resource "google_storage_bucket_object" "dag" {
  name           = "dags/telemetry_quality_gate.py"
  bucket         = local.composer_dag_bucket
  source         = "${path.module}/dags/telemetry_quality_gate.py"
  content_type   = "text/x-python"
  detect_md5hash = filemd5("${path.module}/dags/telemetry_quality_gate.py")
}
