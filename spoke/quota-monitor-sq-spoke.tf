# Provider configuration
provider "aws" {
  region = var.aws_region
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "event_bus_arn" {
  description = "Arn for the EventBridge bus in the monitoring account"
  type        = string
}

variable "spoke_sns_region" {
  description = "Region in which the spoke SNS stack exists in this account"
  type        = string
  default     = ""
}

variable "notification_threshold" {
  description = "Threshold percentage for quota utilization alerts (0-100)"
  type        = string
  default     = "80"
  validation {
    condition     = can(regex("^([1-9]|[1-9][0-9])$", var.notification_threshold))
    error_message = "Threshold must be a whole number between 0 and 100"
  }
}

variable "monitoring_frequency" {
  description = "Frequency to monitor quota utilization"
  type        = string
  default     = "rate(12 hours)"
  validation {
    condition     = contains(["rate(6 hours)", "rate(12 hours)", "rate(1 day)"], var.monitoring_frequency)
    error_message = "Invalid monitoring frequency"
  }
}

variable "report_ok_notifications" {
  description = "Report OK Notifications"
  type        = string
  default     = "No"
  validation {
    condition     = contains(["Yes", "No"], var.report_ok_notifications)
    error_message = "Value must be Yes or No"
  }
}

variable "sagemaker_monitoring" {
  description = "Enable monitoring for SageMaker quotas"
  type        = string
  default     = "Yes"
  validation {
    condition     = contains(["Yes", "No"], var.sagemaker_monitoring)
    error_message = "Value must be Yes or No"
  }
}

variable "connect_monitoring" {
  description = "Enable monitoring for Connect quotas"
  type        = string
  default     = "Yes"
  validation {
    condition     = contains(["Yes", "No"], var.connect_monitoring)
    error_message = "Value must be Yes or No"
  }
}

# Local variables
locals {
  spoke_sns_region_exists = var.spoke_sns_region != ""
  solution_version = "v6.3.0"
  solution_id = "SO0005"
}

# EventBus
resource "aws_cloudwatch_event_bus" "quota_monitor_spoke" {
  name = "QuotaMonitorSpokeBus"
}

# Lambda Layer
resource "aws_lambda_layer_version" "utils_layer" {
  filename            = "asset.e8b91b89616aa81e100a9f9ce53981ad5df4ba7439cebca83d5dc68349ed3703.zip"
  layer_name          = "QM-UtilsLayer-quota-monitor-sq-spoke"
  compatible_runtimes = ["nodejs18.x"]
  s3_bucket          = "solutions-${var.aws_region}"
  s3_key             = "quota-monitor-for-aws/${local.solution_version}/assete8b91b89616aa81e100a9f9ce53981ad5df4ba7439cebca83d5dc68349ed3703.zip"
}

# DynamoDB Tables
resource "aws_dynamodb_table" "service_table" {
  name           = "SQ-ServiceTable"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "ServiceCode"
  stream_enabled = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "ServiceCode"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table" "quota_table" {
  name           = "SQ-QuotaTable"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "ServiceCode"
  range_key      = "QuotaCode"

  attribute {
    name = "ServiceCode"
    type = "S"
  }

  attribute {
    name = "QuotaCode"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

# Dead Letter Queue for CW Poller
resource "aws_sqs_queue" "poller_dlq" {
  name = "QM-CWPoller-Lambda-Dead-Letter-Queue"
  kms_master_key_id = "alias/aws/sqs"
}

resource "aws_sqs_queue_policy" "poller_dlq_policy" {
  queue_url = aws_sqs_queue.poller_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "sqs:*"
        Resource = aws_sqs_queue.poller_dlq.arn
        Condition = {
          Bool = {
            "aws:SecureTransport": "false"
          }
        }
      }
    ]
  })
}

# IAM Roles
resource "aws_iam_role" "list_manager_role" {
  name = "QM-ListManager-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  managed_policy_arns = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
}

resource "aws_iam_role_policy" "list_manager_policy" {
  name = "QM-ListManager-Policy"
  role = aws_iam_role.list_manager_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.service_table.arn,
          aws_dynamodb_table.quota_table.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "servicequotas:ListServiceQuotas",
          "servicequotas:ListServices",
          "dynamodb:DescribeLimits",
          "autoscaling:DescribeAccountLimits",
          "route53:GetAccountLimit",
          "rds:DescribeAccountAttributes"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "dynamodb:ListStreams"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeStream",
          "dynamodb:GetRecords",
          "dynamodb:GetShardIterator"
        ]
        Resource = aws_dynamodb_table.service_table.stream_arn
      }
    ]
  })
}

# CW Poller Lambda Role
resource "aws_iam_role" "cw_poller_role" {
  name = "QM-CWPoller-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  managed_policy_arns = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
}

resource "aws_iam_role_policy" "cw_poller_policy" {
  name = "QM-CWPoller-Policy"
  role = aws_iam_role.cw_poller_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.poller_dlq.arn
      },
      {
        Effect = "Allow"
        Action = "dynamodb:Query"
        Resource = aws_dynamodb_table.quota_table.arn
      },
      {
        Effect = "Allow"
        Action = "dynamodb:Scan"
        Resource = aws_dynamodb_table.service_table.arn
      },
      {
        Effect = "Allow"
        Action = "cloudwatch:GetMetricData"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.quota_monitor_spoke.arn
      },
      {
        Effect = "Allow"
        Action = "servicequotas:ListServices"
        Resource = "*"
      }
    ]
  })
}

# Event Rules IAM Roles
resource "aws_iam_role" "events_role_ok" {
  name = "QM-Events-OK-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "events_policy_ok" {
  name = "QM-Events-OK-Policy"
  role = aws_iam_role.events_role_ok.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "events:PutEvents"
        Resource = var.event_bus_arn
      }
    ]
  })
}

# Similar roles for WARN and ERROR events
resource "aws_iam_role" "events_role_warn" {
  name = "QM-Events-Warn-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "events_policy_warn" {
  name = "QM-Events-Warn-Policy"
  role = aws_iam_role.events_role_warn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "events:PutEvents"
        Resource = var.event_bus_arn
      }
    ]
  })
}

resource "aws_iam_role" "events_role_error" {
  name = "QM-Events-Error-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "events_policy_error" {
  name = "QM-Events-Error-Policy"
  role = aws_iam_role.events_role_error.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "events:PutEvents"
        Resource = var.event_bus_arn
      }
    ]
  })
}

# Lambda Functions
resource "aws_lambda_function" "list_manager" {
  filename         = "asset.3701f2abae7e46f2ca278d27abfbafbf17499950bb5782fed31eb776c07ad072.zip"
  function_name    = "QM-ListManager-Function"
  role            = aws_iam_role.list_manager_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 900
  memory_size     = 256
  description     = "SO0005 quota-monitor-for-aws - QM-ListManager-Function"

  layers = [aws_lambda_layer_version.utils_layer.arn]

  environment {
    variables = {
      SQ_SERVICE_TABLE       = aws_dynamodb_table.service_table.name
      SQ_QUOTA_TABLE        = aws_dynamodb_table.quota_table.name
      PARTITION_KEY         = "ServiceCode"
      SORT                  = "QuotaCode"
      LOG_LEVEL            = "info"
      CUSTOM_SDK_USER_AGENT = "AwsSolution/${local.solution_id}/${local.solution_version}"
      VERSION              = local.solution_version
      SOLUTION_ID          = local.solution_id
    }
  }
}

resource "aws_lambda_function_event_invoke_config" "list_manager_config" {
  function_name = aws_lambda_function.list_manager.function_name
  maximum_event_age_in_seconds = 14400
  qualifier     = "$LATEST"
}

resource "aws_lambda_event_source_mapping" "list_manager_dynamodb" {
  event_source_arn  = aws_dynamodb_table.service_table.stream_arn
  function_name     = aws_lambda_function.list_manager.arn
  starting_position = "LATEST"
  batch_size        = 1
}

resource "aws_lambda_function" "cw_poller" {
  filename         = "asset.4ae69af36e954d598ae25d7f2f8f5ea5ecb93bf4ba61963aa7d8d571cf71ecce.zip"
  function_name    = "QM-CWPoller-Function"
  role            = aws_iam_role.cw_poller_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 900
  memory_size     = 512
  description     = "SO0005 quota-monitor-for-aws - QM-CWPoller-Function"

  dead_letter_config {
    target_arn = aws_sqs_queue.poller_dlq.arn
  }

  layers = [aws_lambda_layer_version.utils_layer.arn]

  environment {
    variables = {
      SQ_SERVICE_TABLE           = aws_dynamodb_table.service_table.name
      SQ_QUOTA_TABLE            = aws_dynamodb_table.quota_table.name
      SPOKE_EVENT_BUS           = aws_cloudwatch_event_bus.quota_monitor_spoke.name
      POLLER_FREQUENCY          = var.monitoring_frequency
      THRESHOLD                 = var.notification_threshold
      SQ_REPORT_OK_NOTIFICATIONS = var.report_ok_notifications
      LOG_LEVEL                 = "info"
      CUSTOM_SDK_USER_AGENT     = "AwsSolution/${local.solution_id}/${local.solution_version}"
      VERSION                   = local.solution_version
      SOLUTION_ID               = local.solution_id
    }
  }
}

resource "aws_lambda_function_event_invoke_config" "cw_poller_config" {
  function_name = aws_lambda_function.cw_poller.function_name
  maximum_event_age_in_seconds = 14400
  qualifier     = "$LATEST"
}

# Event Rules
resource "aws_cloudwatch_event_rule" "list_manager_schedule" {
  name                = "QM-ListManager-Schedule"
  description         = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-EventsRule"
  schedule_expression = "rate(30 days)"
  state              = "ENABLED"

  targets {
    target_id = "Target0"
    arn       = aws_lambda_function.list_manager.arn
  }
}

resource "aws_cloudwatch_event_rule" "cw_poller_schedule" {
  name                = "QM-CWPoller-Schedule"
  description         = "SO0005 quota-monitor-for-aws - QM-CWPoller-EventsRule"
  schedule_expression = var.monitoring_frequency
  state              = "ENABLED"

  targets {
    target_id = "Target0"
    arn       = aws_lambda_function.cw_poller.arn
  }
}

# Event Rules for Utilization Monitoring
resource "aws_cloudwatch_event_rule" "utilization_ok" {
  name           = "QM-Utilization-OK"
  description    = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-EventsRule"
  event_bus_name = aws_cloudwatch_event_bus.quota_monitor_spoke.name
  event_pattern  = jsonencode({
    account     = [data.aws_caller_identity.current.account_id]
    detail      = {
      status = ["OK"]
    }
    detail-type = ["Service Quotas Utilization Notification"]
    source      = ["aws-solutions.quota-monitor"]
  })
  state = "ENABLED"

  targets {
    target_id = "Target0"
    arn       = var.event_bus_arn
    role_arn  = aws_iam_role.events_role_ok.arn
  }
}

resource "aws_cloudwatch_event_rule" "utilization_warn" {
  name           = "QM-Utilization-Warn"
  description    = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-EventsRule"
  event_bus_name = aws_cloudwatch_event_bus.quota_monitor_spoke.name
  event_pattern  = jsonencode({
    account     = [data.aws_caller_identity.current.account_id]
    detail      = {
      status = ["WARN"]
    }
    detail-type = ["Service Quotas Utilization Notification"]
    source      = ["aws-solutions.quota-monitor"]
  })
  state = "ENABLED"

  targets {
    target_id = "Target0"
    arn       = var.event_bus_arn
    role_arn  = aws_iam_role.events_role_warn.arn
  }
}

resource "aws_cloudwatch_event_rule" "utilization_error" {
  name           = "QM-Utilization-Error"
  description    = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-EventsRule"
  event_bus_name = aws_cloudwatch_event_bus.quota_monitor_spoke.name
  event_pattern  = jsonencode({
    account     = [data.aws_caller_identity.current.account_id]
    detail      = {
      status = ["ERROR"]
    }
    detail-type = ["Service Quotas Utilization Notification"]
    source      = ["aws-solutions.quota-monitor"]
  })
  state = "ENABLED"

  targets {
    target_id = "Target0"
    arn       = var.event_bus_arn
    role_arn  = aws_iam_role.events_role_error.arn
  }
}

# SNS Spoke Rule (Conditional)
resource "aws_cloudwatch_event_rule" "spoke_sns" {
  count          = local.spoke_sns_region_exists ? 1 : 0
  name           = "SpokeSnsRule"
  description    = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-SpokeSnsEventsRule"
  event_bus_name = aws_cloudwatch_event_bus.quota_monitor_spoke.name
  event_pattern  = jsonencode({
    detail = {
      status = ["WARN", "ERROR"]
    }
    detail-type = [
      "Trusted Advisor Check Item Refresh Notification",
      "Service Quotas Utilization Notification"
    ]
    source = [
      "aws.trustedadvisor",
      "aws-solutions.quota-monitor"
    ]
  })
  state = "ENABLED"

  targets {
    target_id = "Target0"
    arn       = "arn:${data.aws_partition.current.partition}:events:${var.spoke_sns_region}:${data.aws_caller_identity.current.account_id}:event-bus/QuotaMonitorSnsSpokeBus"
    role_arn  = aws_iam_role.spoke_sns_events_role[0].arn
  }
}

resource "aws_iam_role" "spoke_sns_events_role" {
  count = local.spoke_sns_region_exists ? 1 : 0
  name  = "SpokeSnsEventsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "spoke_sns_events_policy" {
  count = local.spoke_sns_region_exists ? 1 : 0
  name  = "SpokeSnsEventsPolicy"
  role  = aws_iam_role.spoke_sns_events_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "events:PutEvents"
        Resource = "arn:${data.aws_partition.current.partition}:events:${var.spoke_sns_region}:${data.aws_caller_identity.current.account_id}:event-bus/QuotaMonitorSnsSpokeBus"
      }
    ]
  })
}

# Lambda Permissions
resource "aws_lambda_permission" "list_manager_schedule" {
  statement_id  = "AllowEventRuleInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.list_manager.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.list_manager_schedule.arn
}

resource "aws_lambda_permission" "cw_poller_schedule" {
  statement_id  = "AllowEventRuleInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cw_poller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cw_poller_schedule.arn
}

# AppRegistry Resources
resource "aws_servicecatalog_app_registry_application" "quota_monitor" {
  name        = "QM_SQ-${var.aws_region}-${data.aws_caller_identity.current.account_id}"
  description = "Service Catalog application to track and manage all your resources for the solution quota-monitor-for-aws"

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID     = "${local.solution_id}-SQ"
    SolutionName   = "quota-monitor-for-aws"
    SolutionVersion = local.solution_version
  }
}

resource "aws_servicecatalog_app_registry_attribute_group" "quota_monitor" {
  name        = "QM_SQ-${var.aws_region}-${data.aws_caller_identity.current.account_id}"
  description = "Attribute group for application information"

  attributes = jsonencode({
    solutionID      = "${local.solution_id}-SQ"
    solutionName    = "quota-monitor-for-aws"
    version         = local.solution_version
    applicationType = "AWS-Solutions"
  })

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID     = "${local.solution_id}-SQ"
    SolutionName   = "quota-monitor-for-aws"
    SolutionVersion = local.solution_version
  }
}

resource "aws_servicecatalog_app_registry_attribute_group_association" "quota_monitor" {
  application_arn     = aws_servicecatalog_app_registry_application.quota_monitor.arn
  attribute_group_arn = aws_servicecatalog_app_registry_attribute_group.quota_monitor.arn
}

resource "aws_servicecatalog_app_registry_resource_association" "quota_monitor" {
  application_arn = aws_servicecatalog_app_registry_application.quota_monitor.arn
  resource_arn    = "arn:${data.aws_partition.current.partition}:cloudformation:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stack/${local.solution_id}"
  resource_type   = "CFN_STACK"
}

# Outputs
output "event_bus_arn" {
  description = "ARN of the created EventBridge bus"
  value       = aws_cloudwatch_event_bus.quota_monitor_spoke.arn
}

output "service_table_name" {
  description = "Name of the DynamoDB service table"
  value       = aws_dynamodb_table.service_table.name
}

output "quota_table_name" {
  description = "Name of the DynamoDB quota table"
  value       = aws_dynamodb_table.quota_table.name
}
