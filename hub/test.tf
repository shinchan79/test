# Configure AWS Provider
provider "aws" {
  region = "us-east-1"
}

# Variables
variable "deployment_model" {
  type    = string
  default = "Organizations"
  validation {
    condition     = contains(["Organizations", "Hybrid"], var.deployment_model)
    error_message = "Allowed values for deployment_model are Organizations or Hybrid."
  }
}

variable "management_account_id" {
  type    = string
  default = "*"
  validation {
    condition     = can(regex("^([0-9]{1}\\d{11})|\\*$", var.management_account_id))
    error_message = "Management account ID must be 12 digits or *."
  }
}

variable "regions_list" {
  type    = string
  default = "ALL"
}

variable "sns_spoke_region" {
  type    = string
  default = ""
}

variable "region_concurrency" {
  type    = string
  default = "PARALLEL"
  validation {
    condition     = contains(["PARALLEL", "SEQUENTIAL"], var.region_concurrency)
    error_message = "Allowed values for region_concurrency are PARALLEL or SEQUENTIAL."
  }
}

variable "max_concurrent_percentage" {
  type    = number
  default = 100
  validation {
    condition     = var.max_concurrent_percentage >= 1 && var.max_concurrent_percentage <= 100
    error_message = "Max concurrent percentage must be between 1 and 100."
  }
}

variable "failure_tolerance_percentage" {
  type    = number
  default = 0
  validation {
    condition     = var.failure_tolerance_percentage >= 0 && var.failure_tolerance_percentage <= 100
    error_message = "Failure tolerance percentage must be between 0 and 100."
  }
}

variable "sns_email" {
  type    = string
  default = ""
}

variable "sq_notification_threshold" {
  type    = string
  default = "80"
  validation {
    condition     = can(regex("^([1-9]|[1-9][0-9])$", var.sq_notification_threshold))
    error_message = "Threshold must be a whole number between 1 and 99."
  }
}

variable "sq_monitoring_frequency" {
  type    = string
  default = "rate(12 hours)"
  validation {
    condition     = contains(["rate(6 hours)", "rate(12 hours)", "rate(1 day)"], var.sq_monitoring_frequency)
    error_message = "Invalid monitoring frequency."
  }
}

variable "sq_report_ok_notifications" {
  type    = string
  default = "No"
  validation {
    condition     = contains(["Yes", "No"], var.sq_report_ok_notifications)
    error_message = "Value must be Yes or No."
  }
}

variable "sagemaker_monitoring" {
  type    = string
  default = "Yes"
  validation {
    condition     = contains(["Yes", "No"], var.sagemaker_monitoring)
    error_message = "Value must be Yes or No."
  }
}

variable "connect_monitoring" {
  type    = string
  default = "Yes"
  validation {
    condition     = contains(["Yes", "No"], var.connect_monitoring)
    error_message = "Value must be Yes or No."
  }
}

# Local Variables
locals {
  is_email_enabled = var.sns_email != ""
  is_china_partition = data.aws_partition.current.partition == "aws-cn"
  solution_id = "SO0005"
  version = "v6.3.0"
  ssm_parameters = {
    accounts = "/QuotaMonitor/Accounts"
    organizational_units = "/QuotaMonitor/OUs"
    notification_muting_config = "/QuotaMonitor/NotificationConfiguration"
    regions_list = "/QuotaMonitor/RegionsToDeploy"
  }
}

# Data Sources
data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# KMS Key
resource "aws_kms_key" "quota_monitor" {
  description             = "CMK for AWS resources provisioned by Quota Monitor in this account"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow EventBridge to use the key"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "quota-monitor-kms-key"
  }
}

resource "aws_kms_alias" "quota_monitor" {
  name          = "alias/CMK-KMS-Hub"
  target_key_id = aws_kms_key.quota_monitor.key_id
}

# EventBridge Bus
resource "aws_cloudwatch_event_bus" "quota_monitor" {
  name = "QuotaMonitorBus"
}

# SSM Parameters
resource "aws_ssm_parameter" "organizational_units" {
  name        = local.ssm_parameters.organizational_units
  description = "List of target Organizational Units"
  type        = "StringList"
  value       = "NOP"
}

resource "aws_ssm_parameter" "accounts" {
  count       = var.deployment_model == "Hybrid" ? 1 : 0
  name        = local.ssm_parameters.accounts
  description = "List of target Accounts"
  type        = "StringList"
  value       = "NOP"
}

resource "aws_ssm_parameter" "notification_muting_config" {
  name        = local.ssm_parameters.notification_muting_config
  description = "Muting configuration for services, limits"
  type        = "StringList"
  value       = "NOP"
}

resource "aws_ssm_parameter" "regions_list" {
  name        = local.ssm_parameters.regions_list
  description = "list of regions to deploy spoke resources"
  type        = "StringList"
  value       = var.regions_list
}

# SNS Topic
resource "aws_sns_topic" "quota_monitor" {
  name              = "quota-monitor-notifications"
  kms_master_key_id = aws_kms_key.quota_monitor.id
}

resource "aws_sns_topic_subscription" "email" {
  count     = local.is_email_enabled ? 1 : 0
  topic_arn = aws_sns_topic.quota_monitor.arn
  protocol  = "email"
  endpoint  = var.sns_email
}

# DynamoDB Table
resource "aws_dynamodb_table" "quota_monitor" {
  name           = "quota-monitor-table"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "MessageId"
  range_key      = "TimeStamp"

  attribute {
    name = "MessageId"
    type = "S"
  }

  attribute {
    name = "TimeStamp"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.quota_monitor.arn
  }

  ttl {
    enabled        = true
    attribute_name = "ExpiryTime"
  }
}

# Note: This is a partial conversion. The complete conversion would also include:
# - Lambda functions and their IAM roles
# - EventBridge rules
# - CloudFormation StackSets
# - AppRegistry resources
# - Additional IAM policies and roles
# - SQS queues
# Would you like me to continue with any specific section?
# Previous code remains the same...

# Lambda Layer
resource "aws_lambda_layer_version" "utils" {
  filename            = "lambda-layer.zip"  # You'll need to provide the actual layer code
  layer_name          = "QM-UtilsLayer"
  compatible_runtimes = ["nodejs18.x"]

  source_code_hash = filebase64sha256("lambda-layer.zip")
}

# SNS Publisher Lambda Function
resource "aws_sqs_queue" "sns_publisher_dlq" {
  name              = "quota-monitor-sns-publisher-dlq"
  kms_master_key_id = aws_kms_key.quota_monitor.id
}

resource "aws_sqs_queue_policy" "sns_publisher_dlq" {
  queue_url = aws_sqs_queue.sns_publisher_dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "sqs:*"
        Resource = aws_sqs_queue.sns_publisher_dlq.arn
        Condition = {
          Bool = {
            "aws:SecureTransport": "false"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "sns_publisher" {
  name = "quota-monitor-sns-publisher"

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

resource "aws_iam_role_policy" "sns_publisher" {
  name = "quota-monitor-sns-publisher-policy"
  role = aws_iam_role.sns_publisher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.sns_publisher_dlq.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:CreateGrant"
        ]
        Resource = aws_kms_key.quota_monitor.arn
      },
      {
        Effect = "Allow"
        Action = "kms:ListAliases"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "SNS:Publish"
        Resource = aws_sns_topic.quota_monitor.arn
      },
      {
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = aws_ssm_parameter.notification_muting_config.arn
      }
    ]
  })
}

resource "aws_lambda_function" "sns_publisher" {
  filename         = "sns-publisher.zip"  # You'll need to provide the actual function code
  function_name    = "quota-monitor-sns-publisher"
  role            = aws_iam_role.sns_publisher.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 60
  memory_size     = 128

  dead_letter_config {
    target_arn = aws_sqs_queue.sns_publisher_dlq.arn
  }

  environment {
    variables = {
      QM_NOTIFICATION_MUTING_CONFIG_PARAMETER = aws_ssm_parameter.notification_muting_config.name
      SOLUTION_UUID                          = random_uuid.solution_uuid.result
      METRICS_ENDPOINT                       = "https://metrics.awssolutionsbuilder.com/generic"
      SEND_METRIC                           = "Yes"
      TOPIC_ARN                             = aws_sns_topic.quota_monitor.arn
      LOG_LEVEL                             = "info"
      CUSTOM_SDK_USER_AGENT                 = "AwsSolution/${local.solution_id}/${local.version}"
      VERSION                               = local.version
      SOLUTION_ID                           = local.solution_id
    }
  }

  layers = [aws_lambda_layer_version.utils.arn]

  kms_key_arn = aws_kms_key.quota_monitor.arn
}

resource "aws_lambda_function_event_invoke_config" "sns_publisher" {
  function_name                = aws_lambda_function.sns_publisher.function_name
  maximum_event_age_in_seconds = 14400
  qualifier                    = "$LATEST"
}

resource "aws_cloudwatch_event_rule" "sns_publisher" {
  name        = "quota-monitor-sns-publisher"
  description = "Trigger for the SNS publisher Lambda function"

  event_pattern = jsonencode({
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

  event_bus_name = aws_cloudwatch_event_bus.quota_monitor.name
}

resource "aws_cloudwatch_event_target" "sns_publisher" {
  rule      = aws_cloudwatch_event_rule.sns_publisher.name
  target_id = "SNSPublisherLambda"
  arn       = aws_lambda_function.sns_publisher.arn
}

resource "aws_lambda_permission" "sns_publisher" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sns_publisher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sns_publisher.arn
}

# Summarizer Event Queue
resource "aws_sqs_queue" "summarizer" {
  name              = "quota-monitor-summarizer"
  kms_master_key_id = aws_kms_key.quota_monitor.id
  visibility_timeout_seconds = 60
}

resource "aws_sqs_queue_policy" "summarizer" {
  queue_url = aws_sqs_queue.summarizer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "sqs:*"
        Resource = aws_sqs_queue.summarizer.arn
        Condition = {
          Bool = {
            "aws:SecureTransport": "false"
          }
        }
      },
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = aws_sqs_queue.summarizer.arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "summarizer" {
  name        = "quota-monitor-summarizer"
  description = "Event rule for the summarizer queue"

  event_pattern = jsonencode({
    detail = {
      status = ["OK", "WARN", "ERROR"]
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

  event_bus_name = aws_cloudwatch_event_bus.quota_monitor.name
}

resource "aws_cloudwatch_event_target" "summarizer" {
  rule      = aws_cloudwatch_event_rule.summarizer.name
  target_id = "SummarizerQueue"
  arn       = aws_sqs_queue.summarizer.arn
}

# Random UUID for solution tracking
resource "random_uuid" "solution_uuid" {}

# Note: Still remaining to convert:
# - Reporter Lambda function and resources
# - Deployment Manager Lambda function and resources
# - CloudFormation StackSets
# - AppRegistry resources

# Would you like me to continue with any specific component?
# Previous code remains the same...

# Reporter Lambda Function
resource "aws_sqs_queue" "reporter_dlq" {
  name              = "quota-monitor-reporter-dlq"
  kms_master_key_id = aws_kms_key.quota_monitor.id
}

resource "aws_sqs_queue_policy" "reporter_dlq" {
  queue_url = aws_sqs_queue.reporter_dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "sqs:*"
        Resource = aws_sqs_queue.reporter_dlq.arn
        Condition = {
          Bool = {
            "aws:SecureTransport": "false"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "reporter" {
  name = "quota-monitor-reporter"

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

resource "aws_iam_role_policy" "reporter" {
  name = "quota-monitor-reporter-policy"
  role = aws_iam_role.reporter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.reporter_dlq.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:CreateGrant"
        ]
        Resource = aws_kms_key.quota_monitor.arn
      },
      {
        Effect = "Allow"
        Action = "kms:ListAliases"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.summarizer.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem"
        ]
        Resource = aws_dynamodb_table.quota_monitor.arn
      }
    ]
  })
}

resource "aws_lambda_function" "reporter" {
  filename         = "reporter.zip"  # You'll need to provide the actual function code
  function_name    = "quota-monitor-reporter"
  role            = aws_iam_role.reporter.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 10
  memory_size     = 512

  dead_letter_config {
    target_arn = aws_sqs_queue.reporter_dlq.arn
  }

  environment {
    variables = {
      QUOTA_TABLE    = aws_dynamodb_table.quota_monitor.id
      SQS_URL       = aws_sqs_queue.summarizer.id
      MAX_MESSAGES  = "10"
      MAX_LOOPS     = "10"
      LOG_LEVEL     = "info"
      CUSTOM_SDK_USER_AGENT = "AwsSolution/${local.solution_id}/${local.version}"
      VERSION       = local.version
      SOLUTION_ID   = local.solution_id
    }
  }

  layers = [aws_lambda_layer_version.utils.arn]

  kms_key_arn = aws_kms_key.quota_monitor.arn
}

resource "aws_lambda_function_event_invoke_config" "reporter" {
  function_name                = aws_lambda_function.reporter.function_name
  maximum_event_age_in_seconds = 14400
  qualifier                    = "$LATEST"
}

resource "aws_cloudwatch_event_rule" "reporter" {
  name                = "quota-monitor-reporter"
  description         = "Trigger for the Reporter Lambda function"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "reporter" {
  rule      = aws_cloudwatch_event_rule.reporter.name
  target_id = "ReporterLambda"
  arn       = aws_lambda_function.reporter.arn
}

resource "aws_lambda_permission" "reporter" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reporter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reporter.arn
}

# Deployment Manager Lambda Function
resource "aws_sqs_queue" "deployment_manager_dlq" {
  name              = "quota-monitor-deployment-manager-dlq"
  kms_master_key_id = aws_kms_key.quota_monitor.id
}

resource "aws_sqs_queue_policy" "deployment_manager_dlq" {
  queue_url = aws_sqs_queue.deployment_manager_dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "sqs:*"
        Resource = aws_sqs_queue.deployment_manager_dlq.arn
        Condition = {
          Bool = {
            "aws:SecureTransport": "false"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "deployment_manager" {
  name = "quota-monitor-deployment-manager"

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

resource "aws_iam_role_policy" "deployment_manager" {
  name = "quota-monitor-deployment-manager-policy"
  role = aws_iam_role.deployment_manager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "events:PutPermission",
          "events:RemovePermission"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "events:DescribeEventBus"
        Resource = aws_cloudwatch_event_bus.quota_monitor.arn
      },
      {
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          aws_ssm_parameter.organizational_units.arn,
          aws_ssm_parameter.regions_list.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "organizations:DescribeOrganization",
          "organizations:ListRoots",
          "organizations:ListAccounts",
          "organizations:ListDelegatedAdministrators",
          "organizations:ListAccountsForParent"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "cloudformation:DescribeStackSet"
        Resource = [
          "arn:${data.aws_partition.current.partition}:cloudformation:*:${var.management_account_id}:stackset/QM-*:*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "cloudformation:CreateStackInstances",
          "cloudformation:DeleteStackInstances",
          "cloudformation:ListStackInstances"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:cloudformation:*:${var.management_account_id}:stackset/QM-*:*",
          "arn:${data.aws_partition.current.partition}:cloudformation:*:${var.management_account_id}:stackset-target/QM-*:*/*",
          "arn:${data.aws_partition.current.partition}:cloudformation:*::type/resource/*"
        ]
      }
    ]
  })
}

resource "aws_lambda_function" "deployment_manager" {
  filename         = "deployment-manager.zip"  # You'll need to provide the actual function code
  function_name    = "quota-monitor-deployment-manager"
  role            = aws_iam_role.deployment_manager.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 60
  memory_size     = 512

  dead_letter_config {
    target_arn = aws_sqs_queue.deployment_manager_dlq.arn
  }

  environment {
    variables = {
      EVENT_BUS_NAME     = aws_cloudwatch_event_bus.quota_monitor.name
      EVENT_BUS_ARN      = aws_cloudwatch_event_bus.quota_monitor.arn
      QM_OU_PARAMETER    = aws_ssm_parameter.organizational_units.name
      DEPLOYMENT_MODEL   = var.deployment_model
      REGIONS_LIST      = var.regions_list
      SNS_SPOKE_REGION  = var.sns_spoke_region
      SOLUTION_UUID     = random_uuid.solution_uuid.result
      LOG_LEVEL        = "info"
      CUSTOM_SDK_USER_AGENT = "AwsSolution/${local.solution_id}/${local.version}"
      VERSION          = local.version
      SOLUTION_ID      = local.solution_id
    }
  }

  layers = [aws_lambda_layer_version.utils.arn]

  kms_key_arn = aws_kms_key.quota_monitor.arn
}

resource "aws_cloudwatch_event_rule" "deployment_manager" {
  name        = "quota-monitor-deployment-manager"
  description = "Event rule for Deployment Manager"

  event_pattern = jsonencode({
    "detail-type" = ["Parameter Store Change"]
    source        = ["aws.ssm"]
    resources     = [
      aws_ssm_parameter.organizational_units.arn,
      aws_ssm_parameter.regions_list.arn
    ]
  })
}

resource "aws_cloudwatch_event_target" "deployment_manager" {
  rule      = aws_cloudwatch_event_rule.deployment_manager.name
  target_id = "DeploymentManagerLambda"
  arn       = aws_lambda_function.deployment_manager.arn
}

resource "aws_lambda_permission" "deployment_manager" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.deployment_manager.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.deployment_manager.arn
}

# AppRegistry Resources
resource "aws_servicecatalog_app_registry_application" "quota_monitor" {
  name        = "QM_Hub_Org-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
  description = "Service Catalog application to track and manage all your resources for the solution quota-monitor-for-aws"

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID     = local.solution_id
    SolutionName   = "quota-monitor-for-aws"
    SolutionVersion = local.version
  }
}

resource "aws_servicecatalog_app_registry_attribute_group" "quota_monitor" {
  name        = "QM_Hub_Org-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
  description = "Attribute group for application information"

  attributes = jsonencode({
    solutionID      = local.solution_id
    solutionName    = "quota-monitor-for-aws"
    version         = local.version
    applicationType = "AWS-Solutions"
  })

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID     = local.solution_id
    SolutionName   = "quota-monitor-for-aws"
    SolutionVersion = local.version
  }
}

resource "aws_servicecatalog_app_registry_attribute_group_association" "quota_monitor" {
  application_id     = aws_servicecatalog_app_registry_application.quota_monitor.id
  attribute_group_id = aws_servicecatalog_app_registry_attribute_group.quota_monitor.id
}

resource "aws_servicecatalog_app_registry_resource_association" "quota_monitor" {
  application_id = aws_servicecatalog_app_registry_application.quota_monitor.id
  resource_arn   = "arn:${data.aws_partition.current.partition}:cloudformation:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:stack/${local.solution_id}/*"
  resource_type  = "CFN_STACK"
}

# Outputs
output "uuid" {
  description = "UUID for the deployment"
  value       = random_uuid.solution_uuid.result
}

output "event_bus_arn" {
  description = "Event Bus Arn in hub"
  value       = aws_cloudwatch_event_bus.quota_monitor.arn
}

output "sns_topic_arn" {
  description = "The SNS Topic where notifications are published to"
  value       = aws_sns_topic.quota_monitor.arn
}
