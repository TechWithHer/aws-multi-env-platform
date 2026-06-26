#!/bin/bash
# Deploys the global dashboard infrastructure and publishes the frontend.
#
# Usage: ./modules/dashboard/deploy.sh
#
# What it does:
#   1. terraform apply in environments/global (creates/updates Lambda,
#      API Gateway, DynamoDB, and the S3 frontend bucket)
#   2. Reads the API URL from Terraform outputs
#   3. Injects that URL into modules/dashboard/frontend/index.html
#   4. Uploads the result to the frontend S3 bucket
#
# Run this after any change to modules/dashboard.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # modules/dashboard
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "==> Applying global dashboard infrastructure"
cd "$REPO_ROOT/environments/global"
terraform init -input=false
terraform apply -auto-approve

API_URL=$(terraform output -raw api_url)
BUCKET=$(terraform output -raw frontend_bucket_name)
DASHBOARD_URL=$(terraform output -raw dashboard_url)

echo "==> API URL:        $API_URL"
echo "==> Frontend bucket: $BUCKET"

echo "==> Publishing frontend"
sed "s|__API_URL__|${API_URL}|g" "$SCRIPT_DIR/frontend/index.html" > /tmp/dashboard_index.html

aws s3 cp /tmp/dashboard_index.html "s3://${BUCKET}/index.html" \
  --content-type "text/html" \
  --cache-control "no-cache"

rm /tmp/dashboard_index.html

echo ""
echo "Dashboard deployed: $DASHBOARD_URL"
