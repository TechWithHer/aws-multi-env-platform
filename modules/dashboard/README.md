# Dashboard module

A small operational dashboard surfacing, at a glance, whether dev, stage,
and prod are healthy — built on the platform's existing CloudWatch alarms,
tagging standards, and CI/CD pipeline rather than introducing new
monitoring infrastructure.

## What it shows

For each environment:

- **Status** — healthy / warning / critical, derived from alarm state and tag compliance
- **Alarms** — how many CloudWatch alarms are OK vs firing vs insufficient data
- **Tags ok** — percentage of resources carrying all required governance tags (Project, Environment, ManagedBy, Owner)
- **Resources** — how many tagged resources exist in that environment
- **Deployed** — how long ago the environment was last applied, and by whom

## Why this is called from `environments/global`

The dashboard reads across dev, stage, and prod — it doesn't belong to any
one of them. `environments/global` gives it its own state file, following
the same S3 + DynamoDB-lock backend pattern as the other environments.

## Architecture

```text
Browser ── GET /status ── API Gateway (HTTP API) ── Lambda (status_api)
                                                          │
                              ┌───────────────────────────┼───────────────────────────┐
                              ▼                           ▼                           ▼
                      CloudWatch DescribeAlarms   Tagging API GetResources   DynamoDB deployment_log
```

The frontend is a single static HTML file (`frontend/index.html`) hosted on
S3 static website hosting — no server, no build step. It polls the API
every 30 seconds and falls back to sample data if the API is unreachable,
so the page never shows a blank screen.

## Files in this module

```text
main.tf           Lambda, API Gateway, DynamoDB, S3 — all resources
variables.tf       Module inputs
output.tf          Module outputs (api_url, dashboard_url, etc.)
lambda/            Lambda source — packaged automatically via archive_file
frontend/          Static dashboard HTML/CSS/JS
deploy.sh          Applies Terraform and publishes the frontend in one step
```

## Deploying

```bash
./modules/dashboard/deploy.sh
```

This applies `environments/global`, reads the live API URL from Terraform
outputs, injects it into `frontend/index.html`, and uploads the result to
the frontend S3 bucket.

## Wiring "last deployed" into CI

The dashboard's "last deployed" metric depends on the existing
`.github/workflows/terraform.yml` pipeline writing a record after every
successful `terraform apply`. Add this to the apply step for each
environment (adjust the environment variable name to match your workflow):

```yaml
      - name: Record deployment
        run: |
          aws dynamodb put-item \
            --table-name multi-env-platform-deployment-log \
            --item '{
              "environment":      {"S": "'"${{ matrix.environment }}"'"},
              "last_deployed":    {"S": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"},
              "last_deployed_by": {"S": "github-actions"},
              "commit_sha":       {"S": "'"${{ github.sha }}"'"}
            }'
```

This needs `dynamodb:PutItem` on the deployment log table — add it to
whatever role the pipeline already assumes for Terraform.

## Cost

Lambda free tier, API Gateway HTTP API ($1/million requests), DynamoDB
on-demand, and S3 static hosting — expect well under $1/month.

## Future enhancements

- CloudFront in front of the S3 bucket for HTTPS (currently HTTP-only)
- Cognito or IP allowlisting on the API if this stops being a personal demo
- Slack webhook when an environment flips to critical
