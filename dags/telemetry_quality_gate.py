"""Quality-gated transform pipeline (Cloud Composer / Airflow 2).

gate_open  -> short-circuits if the ingestion-gate flag object exists (pipeline paused by a previous DQ failure)
dq_gate    -> Cloud Build trigger: dbt contract tests + Great Expectations. On failure the build publishes
              to the dq-failures topic (gate function drains ingestion + pages on-call) and this task fails.
dbt_run    -> Cloud Build trigger: builds curated models, only reached when dq_gate passed.
"""
import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import ShortCircuitOperator
from airflow.providers.google.cloud.hooks.gcs import GCSHook
from airflow.providers.google.cloud.operators.cloud_build import CloudBuildRunBuildTriggerOperator

PROJECT_ID = os.environ["PROJECT_ID"]
BUCKET = os.environ["ARTIFACTS_BUCKET"]
FLAG = os.environ["GATE_FLAG_OBJECT"]
SOURCE = {"branch_name": os.environ.get("SOURCE_BRANCH", "main")}


def _gate_open() -> bool:
    paused = GCSHook().exists(bucket_name=BUCKET, object_name=FLAG)
    if paused:
        print(f"Ingestion paused by data-quality gate (gs://{BUCKET}/{FLAG}); skipping run.")
    return not paused


with DAG(
    dag_id="telemetry_quality_gate",
    schedule=os.environ.get("DQ_SCHEDULE", "*/15 * * * *"),
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=1,
    default_args={"owner": "data-platform", "retries": 0},
    dagrun_timeout=timedelta(hours=2),
    tags=["telemetry", "data-quality"],
) as dag:
    gate_open = ShortCircuitOperator(task_id="gate_open", python_callable=_gate_open)

    dq_gate = CloudBuildRunBuildTriggerOperator(
        task_id="dq_gate",
        project_id=PROJECT_ID,
        trigger_id=os.environ["DQ_TRIGGER_ID"],
        source=SOURCE,
        location="global",
        wait=True,
        execution_timeout=timedelta(minutes=45),
    )

    dbt_run = CloudBuildRunBuildTriggerOperator(
        task_id="dbt_run",
        project_id=PROJECT_ID,
        trigger_id=os.environ["DBT_TRIGGER_ID"],
        source=SOURCE,
        location="global",
        wait=True,
        retries=1,
        retry_delay=timedelta(minutes=5),
        execution_timeout=timedelta(minutes=75),
    )

    gate_open >> dq_gate >> dbt_run
