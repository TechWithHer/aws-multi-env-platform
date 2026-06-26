variable "project_name" {
  type        = string
  description = "Project name used for resource naming, alarm-name matching, and tagging"
}

variable "environments" {
  type        = list(string)
  description = "Environment names to track on the dashboard"
  default     = ["dev", "stage", "prod"]
}

variable "required_tags" {
  type        = list(string)
  description = "Tag keys every resource must carry to count as compliant"
  default     = ["Project", "Environment", "ManagedBy", "Owner"]
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to all dashboard resources themselves"
  default     = {}
}
