# Serverless Real-Time Streaming & Lakehouse on GCP (Terraform)

Pub/Sub (Avro schema, DLQs) -> Dataflow streaming (Beam Flex Template) -> BigQuery (partitioned + clustered) and
BigLake managed Iceberg on GCS. Cloud Composer orchestrates dbt + Great Expectations in Cloud Build; a failed gate
flags and drains ingestion and pages on-call via Slack / PagerDuty.

```
producers -> [Pub/Sub topic + Avro schema] -> sub --(5 fails)--> DLQ "undeliverable" -> BQ ops.dead_letter_undeliverable
                                               |
                                      Dataflow (streaming engine, autoscaling, private IPs, CMEK)
                                       |  tumbling+sliding windows     |-- malformed --> DLQ "malformed" -> BQ ops.dead_letter_malformed
                                       v
                       BQ raw.telemetry_events / telemetry_windowed        Iceberg (BigLake) on GCS
                                       |
   Composer DAG: gate_open -> Cloud Build dq_gate (dbt tests + GE) -> Cloud Build dbt_run
                                       | on failure
                       Pub/Sub dq-failures -> gate function: flag object + drain Dataflow + CRITICAL log
                                       -> Monitoring alert -> PagerDuty + Slack + email
```

## What this repo does NOT contain (you supply these)
1. **Beam pipeline + Flex Template image** - parameters Terraform passes (`dataflow.tf`):
   `input_subscription, output_events_table, output_windowed_table, malformed_topic, tumbling_window_seconds,
   sliding_window_seconds, sliding_period_seconds, allowed_lateness_seconds, iceberg_table`.
   Publish the spec to `flex_template_gcs_path` (output), then set `deploy_dataflow_job = true`.
2. **`dq-runner` image** (dbt-bigquery + great_expectations) pushed to the `artifact_registry_repo` output.
3. **dbt/ and data_quality/ directories** in `source_repo_uri` (GitHub, Cloud Build GitHub app installed).
   dbt profiles read `DBT_*` env vars set by the triggers; checkpoint name expected: `telemetry_checkpoint`;
   dbt tests tagged `data_contract`; marts tagged `streaming_marts`.

## Deploy
```bash
terraform init -backend-config="bucket=<state-bucket>" -backend-config="prefix=streaming-lakehouse/prod"
export TF_VAR_slack_auth_token=...  TF_VAR_pagerduty_service_key=...
terraform plan  -var-file=environments/prod.tfvars -out=tfplan
terraform apply tfplan
```
First apply notes: API enablement and service-agent creation can race - if you hit a KMS/permission 403, re-run apply.
Composer takes 25-40 min. Run `terraform fmt -recursive` before committing.

## Gate runbook
- **Pause**: automatic. `gs://<artifacts>/gate/ingestion_paused.json` appears, Dataflow job is drained, Pub/Sub keeps the backlog (7d).
- **Resume**: fix data -> delete the flag object -> `terraform apply` (relaunches the drained job) -> unpause happens on the next DAG run.
- `gate_action = "flag_only"` skips the drain and only blocks downstream Composer runs.

## Cost guardrails built in
Partitioned tables with `require_partition_filter`, clustering, partition expiry, 48h time travel, Dataflow `max_workers` ceiling,
dbt `maximum_bytes_billed` (`dbt_max_bytes_billed`), optional capped autoscaling slot reservation, optional billing budget alerts, GCS lifecycle rules.

## Known caveats
- Pin/verify `composer_image_version` for your date; verify provider schema with `terraform validate` (this was syntax- and reference-checked, not applied).
- BigLake Iceberg tables require provider >= 6.x; set `enable_iceberg_table = false` if your org policy blocks it. Delta Lake alternative: external BigLake table with `source_format = "DELTA_LAKE"`.
- Slack/PagerDuty secrets live in Terraform state: use an encrypted, access-controlled GCS backend.
- Cloud Build runs on the default pool; use a private pool + VPC-SC if your threat model demands it.
