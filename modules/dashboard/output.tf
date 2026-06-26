output "api_url" {
  description = "Base invoke URL for the dashboard status API"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "dashboard_url" {
  description = "S3 static website endpoint serving the dashboard frontend"
  value       = aws_s3_bucket_website_configuration.frontend.website_endpoint
}

output "frontend_bucket_name" {
  description = "S3 bucket name hosting the frontend (used by deploy.sh)"
  value       = aws_s3_bucket.frontend.id
}

output "deployment_log_table" {
  description = "DynamoDB table name the CI/CD pipeline writes deployment records to"
  value       = aws_dynamodb_table.deployment_log.name
}

output "status_api_function_name" {
  description = "Lambda function name for the status API"
  value       = aws_lambda_function.status_api.function_name
}
