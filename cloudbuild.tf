############################
# Data-contract + quality gate (dbt tests + Great Expectations)
#   * Both suites ALWAYS run (neither hides the other's failure).
#   * Final step publishes to the dq-failures topic and fails the build if either suite failed.
#   * The gate function reacts by flagging + draining ingestion and paging the on-call.
############################
locals {
  dbt_tests_script = <<-EOT
    set +e
    dbt deps --profiles-dir ./profiles && \
    dbt test --select "source:* tag:data_contract" --target ci --profiles-dir ./profiles
    echo $$? > /workspace/dbt.rc
    exit 0
  EOT

  ge_script = <<-EOT
    set +e
    great_expectations checkpoint run telemetry_checkpoint
    echo $$? > /workspace/ge.rc
    exit 0
  EOT

  gate_script = <<-EOT
    dbt_rc=$$(cat /workspace/dbt.rc 2>/dev/null || echo 1)
    ge_rc=$$(cat /workspace/ge.rc 2>/dev/null || echo 1)
    echo "dbt_rc=$$dbt_rc ge_rc=$$ge_rc"
    if [ "$$dbt_rc" != "0" ] || [ "$$ge_rc" != "0" ]; then
      gcloud pubsub topics publish "$_DQ_FAILURE_TOPIC" --project="$PROJECT_ID" \
        --attribute="action=pause,build_id=$BUILD_ID,gate_action=$_GATE_ACTION" \
        --message="{\"build_id\":\"$BUILD_ID\",\"dbt_rc\":$$dbt_rc,\"ge_rc\":$$ge_rc}"
      echo "DATA QUALITY GATE FAILED - ingestion pause requested"
      exit 1
    fi
    echo "Data quality gate passed"
  EOT

  dq_common_env = [
    "DBT_BQ_PROJECT=$PROJECT_ID",
    "DBT_BQ_LOCATION=$_BQ_LOCATION",
    "DBT_RAW_DATASET=$_RAW_DATASET",
    "DBT_CURATED_DATASET=$_CURATED_DATASET",
    "DBT_OPS_DATASET=$_OPS_DATASET",
    "DBT_MAX_BYTES_BILLED=$_MAX_BYTES_BILLED",
    "GOOGLE_CLOUD_PROJECT=$PROJECT_ID",
  ]

  cb_substitutions = {
    _BQ_LOCATION      = var.bq_location
    _RAW_DATASET      = google_bigquery_dataset.this["raw"].dataset_id
    _CURATED_DATASET  = google_bigquery_dataset.this["curated"].dataset_id
    _OPS_DATASET      = google_bigquery_dataset.this["ops"].dataset_id
    _DQ_FAILURE_TOPIC = google_pubsub_topic.dq_failures.name
    _GATE_ACTION      = var.gate_action
    _MAX_BYTES_BILLED = tostring(var.dbt_max_bytes_billed)
  }
}

resource "google_cloudbuild_trigger" "dq_gate" {
  name            = "${local.prefix}-dq-gate"
  description     = "dbt tests + Great Expectations; publishes to ${google_pubsub_topic.dq_failures.name} on failure"
  service_account = google_service_account.cloudbuild.id
  substitutions   = local.cb_substitutions

  # No event config => manual trigger, invoked by Composer (and runnable by humans).
  source_to_build {
    uri       = var.source_repo_uri
    ref       = var.source_repo_ref
    repo_type = "GITHUB"
  }

  build {
    timeout = "1800s"

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }

    step {
      id         = "dbt-contract-tests"
      name       = var.dq_runner_image
      dir        = "dbt"
      entrypoint = "bash"
      args       = ["-c", local.dbt_tests_script]
      env        = local.dq_common_env
    }

    step {
      id         = "great-expectations"
      name       = var.dq_runner_image
      dir        = "data_quality"
      entrypoint = "bash"
      args       = ["-c", local.ge_script]
      env        = local.dq_common_env
    }

    step {
      id         = "gate"
      name       = var.gcloud_image
      entrypoint = "bash"
      args       = ["-c", local.gate_script]
    }
  }

  depends_on = [google_project_iam_member.project_roles]
}

resource "google_cloudbuild_trigger" "dbt_run" {
  name            = "${local.prefix}-dbt-run"
  description     = "dbt build of curated models (only reached when the gate passes)"
  service_account = google_service_account.cloudbuild.id
  substitutions   = local.cb_substitutions

  source_to_build {
    uri       = var.source_repo_uri
    ref       = var.source_repo_ref
    repo_type = "GITHUB"
  }

  build {
    timeout = "3600s"

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }

    step {
      id         = "dbt-build"
      name       = var.dq_runner_image
      dir        = "dbt"
      entrypoint = "bash"
      args       = ["-c", "dbt deps --profiles-dir ./profiles && dbt build --select tag:streaming_marts --target prod --profiles-dir ./profiles"]
      env        = local.dq_common_env
    }
  }

  depends_on = [google_project_iam_member.project_roles]
}
