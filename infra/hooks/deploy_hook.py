"""CodeDeploy PreTraffic hook for a newly published Graph RAG Lambda version."""

from __future__ import annotations

import json
import os
import uuid

import boto3


def _report(codedeploy, event: dict, status: str) -> None:
    codedeploy.put_lifecycle_event_hook_execution_status(
        deploymentId=event["DeploymentId"],
        lifecycleEventHookExecutionId=event["LifecycleEventHookExecutionId"],
        status=status,
    )


def handler(event: dict, context) -> None:
    codedeploy = boto3.client("codedeploy")
    lambda_client = boto3.client("lambda")
    deployment_id = event["DeploymentId"]
    payload_base = {
        "kind": "deployment",
        "deployment_id": deployment_id,
        "git_sha": os.environ.get("APP_VERSION", "unknown"),
    }
    try:
        for action in ("migrate", "ready"):
            payload = {**payload_base, "action": action, "request_id": str(uuid.uuid4())}
            response = lambda_client.invoke(
                FunctionName=os.environ["FUNCTION_NAME"],
                Qualifier=os.environ["NEW_VERSION"],
                InvocationType="RequestResponse",
                Payload=json.dumps(payload).encode("utf-8"),
            )
            raw = response["Payload"].read().decode("utf-8")
            if response.get("FunctionError"):
                raise RuntimeError(f"new version {action} failed")
            result = json.loads(raw)
            if result.get("status") not in (None, "ok"):
                raise RuntimeError(f"new version {action} did not become ready")
        _report(codedeploy, event, "Succeeded")
    except Exception:
        # Error detail is intentionally left to the hook's CloudWatch logs;
        # CodeDeploy status and GitHub diagnostics link to that stream.
        _report(codedeploy, event, "Failed")
        raise
