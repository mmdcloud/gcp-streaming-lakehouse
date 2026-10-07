"""Ingestion gate: reacts to data-quality failures published by Cloud Build.

Message attributes
  action       pause (default) | resume
  gate_action  drain | flag_only   (defaults to DEFAULT_ACTION env)
  build_id     Cloud Build id, for traceability

pause  -> write gate flag object, optionally drain the streaming Dataflow job, log INGESTION_PAUSED (CRITICAL)
resume -> delete gate flag object (job relaunch is done by `terraform apply`)

Every step is idempotent so Eventarc retries are safe.
"""
import base64
import json
import os
from datetime import datetime, timezone

import functions_framework
from google.cloud import storage
from googleapiclient.discovery import build

PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ["DATAFLOW_REGION"]
JOB_NAME = os.environ["DATAFLOW_JOB_NAME"]
BUCKET = os.environ["ARTIFACTS_BUCKET"]
FLAG = os.environ["GATE_FLAG_OBJECT"]
DEFAULT_ACTION = os.environ.get("DEFAULT_ACTION", "drain")
VALID_ACTIONS = {"drain", "flag_only"}


def log(severity: str, event: str, **fields) -> None:
    """Structured log line; Cloud Logging maps `severity` and exposes jsonPayload.event for alerting."""
    print(json.dumps({"severity": severity, "event": event, "message": event, **fields}), flush=True)


def _flag_blob():
    return storage.Client(project=PROJECT_ID).bucket(BUCKET).blob(FLAG)


def set_flag(build_id: str, detail: dict) -> None:
    _flag_blob().upload_from_string(
        json.dumps(
            {
                "paused_at": datetime.now(timezone.utc).isoformat(),
                "build_id": build_id,
                "detail": detail,
            }
        ),
        content_type="application/json",
    )


def clear_flag() -> bool:
    blob = _flag_blob()
    if blob.exists():
        blob.delete()
        return True
    return False


def drain_streaming_jobs() -> list:
    df = build("dataflow", "v1b3", cache_discovery=False)
    jobs_api = df.projects().locations().jobs()
    drained = []
    request = jobs_api.list(projectId=PROJECT_ID, location=REGION, filter="ACTIVE")
    while request is not None:
        resp = request.execute()
        for job in resp.get("jobs", []):
            if job.get("name") == JOB_NAME and job.get("type") == "JOB_TYPE_STREAMING":
                if job.get("requestedState") == "JOB_STATE_DRAINING":
                    continue
                jobs_api.update(
                    projectId=PROJECT_ID,
                    location=REGION,
                    jobId=job["id"],
                    body={"requestedState": "JOB_STATE_DRAINING"},
                ).execute()
                drained.append(job["id"])
        request = jobs_api.list_next(previous_request=request, previous_response=resp)
    return drained


@functions_framework.cloud_event
def handle(cloud_event):
    message = cloud_event.data.get("message", {})
    attrs = message.get("attributes") or {}
    body = {}
    if message.get("data"):
        try:
            body = json.loads(base64.b64decode(message["data"]))
        except Exception:  # noqa: BLE001 - payload is advisory only
            body = {"unparseable": True}

    action = attrs.get("action", "pause")
    build_id = attrs.get("build_id") or body.get("build_id", "unknown")
    gate_action = attrs.get("gate_action", DEFAULT_ACTION)
    if gate_action not in VALID_ACTIONS:
        log("ERROR", "INGESTION_GATE_BAD_ACTION", gate_action=gate_action, build_id=build_id)
        return  # poison message: do not retry

    if action == "pause":
        set_flag(build_id, body)
        drained = []
        if gate_action == "drain":
            drained = drain_streaming_jobs()  # raises on API errors -> Eventarc retry
        log(
            "CRITICAL",
            "INGESTION_PAUSED",
            build_id=build_id,
            gate_action=gate_action,
            drained_jobs=drained,
            detail=body,
        )
    elif action == "resume":
        removed = clear_flag()
        log("WARNING", "INGESTION_RESUME_REQUESTED", build_id=build_id, flag_removed=removed,
            note="Run terraform apply to relaunch a drained Dataflow job.")
    else:
        log("ERROR", "INGESTION_GATE_BAD_ACTION", action=action, build_id=build_id)
