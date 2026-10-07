project_id          = "my-data-platform-dev"
region              = "asia-south1"
bq_location         = "asia-south1"
environment         = "dev"
deletion_protection = false

dq_runner_image = "asia-south1-docker.pkg.dev/my-data-platform-dev/tlm-dev-images/dq-runner:1.0.0"
source_repo_uri = "https://github.com/YOUR_ORG/telemetry-data-platform"

# Flip to true after publishing the Flex Template (see README)
deploy_dataflow_job  = false
dataflow_max_workers = 3

enable_bq_reservation  = false
bq_max_autoscale_slots = 100
billing_account_id     = null # "XXXXXX-XXXXXX-XXXXXX"
monthly_budget_amount  = 150

alert_emails       = ["data-oncall@example.com"]
slack_channel_name = "#data-alerts"
# slack_auth_token / pagerduty_service_key: export TF_VAR_slack_auth_token=... TF_VAR_pagerduty_service_key=...
