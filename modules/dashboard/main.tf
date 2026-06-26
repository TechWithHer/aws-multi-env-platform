# ─────────────────────────────────────────────────────────────────────
# Dashboard module
#
# Provisions a status API (Lambda + API Gateway) that aggregates
# CloudWatch alarm state, tag compliance, and last-deployment info
# across all environments, plus a static S3-hosted frontend that
# displays it.
#
# This module is cross-environment by design and is intended to be
# called once from environments/global, not from dev/stage/prod.
# ─────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── Deployment log — written to by the CI/CD pipeline on every apply ──
resource "aws_dynamodb_table" "deployment_log" {
  name         = "${var.project_name}-deployment-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "environment"

  attribute {
    name = "environment"
    type = "S"
  }

  tags = var.tags
}

# ── Package the Lambda source automatically on every apply ───────────
# Self-contained: source lives inside this module at ./lambda/
data "archive_file" "status_api" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_function.py"
  output_path = "${path.module}/build/status_api.zip"
}

# ── IAM role: read-only access, scoped tightly ────────────────────────
resource "aws_iam_role" "status_api" {
  name = "${var.project_name}-dashboard-status-api"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "status_api" {
  name = "status-api-read-only"
  role = aws_iam_role.status_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CloudWatchAlarmsReadOnly"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = "*"
      },
      {
        Sid      = "TaggingReadOnly"
        Effect   = "Allow"
        Action   = ["tag:GetResources"]
        Resource = "*"
      },
      {
        Sid      = "DeploymentLogReadOnly"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = aws_dynamodb_table.deployment_log.arn
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ── Lambda function ────────────────────────────────────────────────
resource "aws_lambda_function" "status_api" {
  function_name = "${var.project_name}-dashboard-status-api"
  role          = aws_iam_role.status_api.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"
  timeout       = 15
  memory_size   = 128

  filename         = data.archive_file.status_api.output_path
  source_code_hash = data.archive_file.status_api.output_base64sha256

  environment {
    variables = {
      PROJECT_NAME         = var.project_name
      ENVIRONMENTS         = join(",", var.environments)
      DEPLOYMENT_LOG_TABLE = aws_dynamodb_table.deployment_log.name
      REQUIRED_TAGS        = join(",", var.required_tags)
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "status_api" {
  name              = "/aws/lambda/${aws_lambda_function.status_api.function_name}"
  retention_in_days = 7
  tags              = var.tags
}

# ── API Gateway — HTTP API (cheaper than REST API for a single route) ──
resource "aws_apigatewayv2_api" "dashboard" {
  name          = "${var.project_name}-dashboard-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"] # tighten to the S3 website origin if needed
    allow_methods = ["GET", "OPTIONS"]
    allow_headers = ["content-type"]
  }

  tags = var.tags
}

resource "aws_apigatewayv2_integration" "status_api" {
  api_id                 = aws_apigatewayv2_api.dashboard.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.status_api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "status" {
  api_id    = aws_apigatewayv2_api.dashboard.id
  route_key = "GET /status"
  target    = "integrations/${aws_apigatewayv2_integration.status_api.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.dashboard.id
  name        = "$default"
  auto_deploy = true
  tags        = var.tags
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.status_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.dashboard.execution_arn}/*/*"
}

# ── Frontend hosting — S3 static website ──────────────────────────
resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-dashboard-${data.aws_caller_identity.current.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }
}

# Public read is required for S3 static website hosting without CloudFront.
# Promote to CloudFront + Origin Access Control for a production deployment.
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}
