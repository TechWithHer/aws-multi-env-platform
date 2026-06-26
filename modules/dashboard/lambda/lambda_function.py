#!/usr/bin/env python3
"""
Dashboard Status API — Lambda Handler

Aggregates infrastructure health across dev/stage/prod environments for the
Infrastructure Status Dashboard frontend.

For each environment, this returns:
  - alarm counts (ok / alarm / insufficient_data) from CloudWatch
  - tag compliance percentage from Resource Groups Tagging API
  - resource count
  - last deployment timestamp + actor from a DynamoDB deployment log

Required environment variables:
  PROJECT_NAME          - e.g. "multi-env-platform" (used as alarm name prefix)
  ENVIRONMENTS          - comma-separated, e.g. "dev,stage,prod"
  DEPLOYMENT_LOG_TABLE   - DynamoDB table name
  REQUIRED_TAGS          - comma-separated tags every resource must have,
                           e.g. "Project,Environment,ManagedBy,Owner"

IAM permissions needed:
  cloudwatch:DescribeAlarms
  tag:GetResources
  dynamodb:GetItem  (on DEPLOYMENT_LOG_TABLE only)
"""

import json
import os
from datetime import datetime, timezone

import boto3

cloudwatch = boto3.client("cloudwatch")
tagging    = boto3.client("resourcegroupstaggingapi")
dynamodb   = boto3.resource("dynamodb")

PROJECT_NAME         = os.environ["PROJECT_NAME"]
ENVIRONMENTS         = os.environ.get("ENVIRONMENTS", "dev,stage,prod").split(",")
DEPLOYMENT_LOG_TABLE  = os.environ["DEPLOYMENT_LOG_TABLE"]
REQUIRED_TAGS         = os.environ.get("REQUIRED_TAGS", "Project,Environment,ManagedBy,Owner").split(",")

CORS_HEADERS = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Methods": "GET,OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Content-Type": "application/json",
}


def get_alarm_summary(environment: str) -> dict:
    """
    Count alarms by state for one environment.

    Relies on the project's naming convention: every alarm is named
    "<project>-<purpose>-<environment>", matching how alarms are created
    in modules/monitoring. Pagination is handled in case of >100 alarms.
    """
    ok = alarm = insufficient = 0
    paginator = cloudwatch.get_paginator("describe_alarms")

    for page in paginator.paginate(AlarmNamePrefix=f"{PROJECT_NAME}-"):
        for a in page.get("MetricAlarms", []):
            if not a["AlarmName"].endswith(f"-{environment}"):
                continue
            state = a.get("StateValue", "INSUFFICIENT_DATA")
            if state == "OK":
                ok += 1
            elif state == "ALARM":
                alarm += 1
            else:
                insufficient += 1

    return {"ok": ok, "alarm": alarm, "insufficient": insufficient}


def get_tag_compliance(environment: str) -> dict:
    """
    Check what fraction of resources tagged Environment=<environment>
    also carry every tag in REQUIRED_TAGS.

    Returns {"resource_count": int, "compliance_pct": int}
    """
    paginator = tagging.get_paginator("get_resources")
    total = 0
    compliant = 0

    for page in paginator.paginate(
        TagFilters=[{"Key": "Environment", "Values": [environment]}]
    ):
        for resource in page.get("ResourceTagMappingList", []):
            total += 1
            present_keys = {t["Key"] for t in resource.get("Tags", [])}
            if all(tag in present_keys for tag in REQUIRED_TAGS):
                compliant += 1

    if total == 0:
        return {"resource_count": 0, "compliance_pct": 100}

    return {
        "resource_count":  total,
        "compliance_pct":  round((compliant / total) * 100),
    }


def get_last_deployment(environment: str) -> dict:
    """Read the last deployment record written by the CI/CD pipeline."""
    table = dynamodb.Table(DEPLOYMENT_LOG_TABLE)

    try:
        resp = table.get_item(Key={"environment": environment})
    except Exception as e:
        print(f"[WARN] Could not read deployment log for {environment}: {e}")
        return {"last_deployed": None, "last_deployed_by": None, "commit_sha": None}

    item = resp.get("Item")
    if not item:
        return {"last_deployed": None, "last_deployed_by": None, "commit_sha": None}

    return {
        "last_deployed":    item.get("last_deployed"),
        "last_deployed_by": item.get("last_deployed_by"),
        "commit_sha":       item.get("commit_sha"),
    }


def derive_status(alarms: dict, tag_compliance_pct: int) -> str:
    """
    Roll up alarm state and tag compliance into a single status:
    critical > warning > healthy.
    """
    if alarms["alarm"] > 0:
        return "critical"
    if alarms["insufficient"] > 0 or tag_compliance_pct < 100:
        return "warning"
    return "healthy"


def lambda_handler(event, context):
    """API Gateway HTTP API (payload format 2.0) entry point."""

    # Handle CORS preflight
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    if method == "OPTIONS":
        return {"statusCode": 200, "headers": CORS_HEADERS, "body": ""}

    environments_data = {}

    for env in ENVIRONMENTS:
        env = env.strip()
        try:
            alarms     = get_alarm_summary(env)
            tags       = get_tag_compliance(env)
            deployment = get_last_deployment(env)
            status     = derive_status(alarms, tags["compliance_pct"])

            environments_data[env] = {
                "status":             status,
                "alarms":             alarms,
                "tag_compliance_pct": tags["compliance_pct"],
                "resource_count":     tags["resource_count"],
                "last_deployed":      deployment["last_deployed"],
                "last_deployed_by":   deployment["last_deployed_by"],
                "commit_sha":         deployment["commit_sha"],
            }
        except Exception as e:
            print(f"[ERROR] Failed to gather status for {env}: {e}")
            environments_data[env] = {
                "status": "unknown",
                "error":  str(e),
            }

    body = {
        "generated_at":  datetime.now(timezone.utc).isoformat(),
        "environments":  environments_data,
    }

    return {
        "statusCode": 200,
        "headers":    CORS_HEADERS,
        "body":       json.dumps(body),
    }
