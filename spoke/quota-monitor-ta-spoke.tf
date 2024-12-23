# Configure Terraform AWS Provider
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Variables
variable "event_bus_arn" {
  type = string
  description = "Arn for the EventBridge bus in the monitoring account"
}

variable "ta_refresh_rate" {
  type        = string
  description = "The rate at which to refresh Trusted Advisor checks"
  default     = "rate(12 hours)"
  validation {
    condition     = contains(["rate(6 hours)", "rate(12 hours)", "rate(1 day)"], var.ta_refresh_rate)
    error_message = "Allowed values are: rate(6 hours), rate(12 hours), rate(1 day)"
  }
}

locals {
  monitored_services = ["AutoScaling", "CloudFormation", "DynamoDB", "EBS", "EC2", "ELB", "IAM", "Kinesis", "RDS", "Route53", "SES", "VPC"]
}

# EventBridge Rules and IAM Roles for OK status
resource "aws_cloudwatch_event_rule" "ta_ok_rule" {
  description = "Quota Monitor Solution - Spoke - Rule for TA OK events"
  
  event_pattern = jsonencode({
    account = [data.aws_caller_identity.current.account_id]
    detail = {
      status = ["OK"]
      check-item-detail = {
        Service = local.monitored_services
      }
    }
    detail-type = ["Trusted Advisor Check Item Refresh Notification"]
    source      = ["aws.trustedadvisor"]
  })

  state = "ENABLED"
}

resource "aws_cloudwatch_event_target" "ta_ok_target" {
  rule      = aws_cloudwatch_event_rule.ta_ok_rule.name
  target_id = "Target0"
  arn       = var.event_bus_arn
  role_arn  = aws_iam_role.ta_ok_events_role.arn
}

resource "aws_iam_role" "ta_ok_events_role" {
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

resource "aws_iam_role_policy" "ta_ok_events_policy" {
  role = aws_iam_role.ta_ok_events_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "events:PutEvents"
        Effect   = "Allow"
        Resource = var.event_bus_arn
      }
    ]
  })
}

# EventBridge Rules and IAM Roles for WARN status
resource "aws_cloudwatch_event_rule" "ta_warn_rule" {
  description = "Quota Monitor Solution - Spoke - Rule for TA WARN events"
  
  event_pattern = jsonencode({
    account = [data.aws_caller_identity.current.account_id]
    detail = {
      status = ["WARN"]
      check-item-detail = {
        Service = local.monitored_services
      }
    }
    detail-type = ["Trusted Advisor Check Item Refresh Notification"]
    source      = ["aws.trustedadvisor"]
  })

  state = "ENABLED"
}

resource "aws_cloudwatch_event_target" "ta_warn_target" {
  rule      = aws_cloudwatch_event_rule.ta_warn_rule.name
  target_id = "Target0"
  arn       = var.event_bus_arn
  role_arn  = aws_iam_role.ta_warn_events_role.arn
}

resource "aws_iam_role" "ta_warn_events_role" {
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

resource "aws_iam_role_policy" "ta_warn_events_policy" {
  role = aws_iam_role.ta_warn_events_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "events:PutEvents"
        Effect   = "Allow"
        Resource = var.event_bus_arn
      }
    ]
  })
}

# EventBridge Rules and IAM Roles for ERROR status
resource "aws_cloudwatch_event_rule" "ta_error_rule" {
  description = "Quota Monitor Solution - Spoke - Rule for TA ERROR events"
  
  event_pattern = jsonencode({
    account = [data.aws_caller_identity.current.account_id]
    detail = {
      status = ["ERROR"]
      check-item-detail = {
        Service = local.monitored_services
      }
    }
    detail-type = ["Trusted Advisor Check Item Refresh Notification"]
    source      = ["aws.trustedadvisor"]
  })

  state = "ENABLED"
}

resource "aws_cloudwatch_event_target" "ta_error_target" {
  rule      = aws_cloudwatch_event_rule.ta_error_rule.name
  target_id = "Target0"
  arn       = var.event_bus_arn
  role_arn  = aws_iam_role.ta_error_events_role.arn
}

resource "aws_iam_role" "ta_error_events_role" {
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

resource "aws_iam_role_policy" "ta_error_events_policy" {
  role = aws_iam_role.ta_error_events_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "events:PutEvents"
        Effect   = "Allow"
        Resource = var.event_bus_arn
      }
    ]
  })
}

# Lambda Layer
resource "aws_lambda_layer_version" "utils_layer" {
  layer_name          = "QM-UtilsLayer"
  description         = "Quota Monitor Utils Layer"
  compatible_runtimes = ["nodejs18.x"]
  s3_bucket          = "solutions-${data.aws_region.current.name}"
  s3_key             = "quota-monitor-for-aws/v6.3.0/assete8b91b89616aa81e100a9f9ce53981ad5df4ba7439cebca83d5dc68349ed3703.zip"
}

# Dead Letter Queue
resource "aws_sqs_queue" "lambda_dlq" {
  name              = "qm-ta-refresher-lambda-dlq"
  kms_master_key_id = "alias/aws/sqs"
}

resource "aws_sqs_queue_policy" "lambda_dlq_policy" {
  queue_url = aws_sqs_queue.lambda_dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "sqs:*"
        Resource = aws_sqs_queue.lambda_dlq.arn
        Condition = {
          Bool = {
            "aws:SecureTransport": "false"
          }
        }
      }
    ]
  })
}

# Lambda Function
resource "aws_lambda_function" "ta_refresher" {
  filename         = "lambda/ta-refresher.zip" # You'll need to provide the actual Lambda code
  function_name    = "QM-TA-Refresher"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 60
  memory_size     = 128
  
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  layers = [aws_lambda_layer_version.utils_layer.arn]

  environment {
    variables = {
      AWS_SERVICES           = join(",", local.monitored_services)
      LOG_LEVEL             = "info"
      CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
      VERSION               = "v6.3.0"
      SOLUTION_ID           = "SO0005"
    }
  }
}

# Lambda IAM Role
resource "aws_iam_role" "lambda_role" {
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

  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
}

resource "aws_iam_role_policy" "lambda_policy" {
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.lambda_dlq.arn
      },
      {
        Effect = "Allow"
        Action = "support:RefreshTrustedAdvisorCheck"
        Resource = "*"
      }
    ]
  })
}

# EventBridge Rule for Lambda
resource "aws_cloudwatch_event_rule" "ta_refresher_rule" {
  description         = "SO0005 quota-monitor-for-aws - QM-TA-Refresher-EventsRule"
  schedule_expression = var.ta_refresh_rate
  state              = "ENABLED"
}

resource "aws_cloudwatch_event_target" "ta_refresher_target" {
  rule      = aws_cloudwatch_event_rule.ta_refresher_rule.name
  target_id = "Target0"
  arn       = aws_lambda_function.ta_refresher.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ta_refresher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ta_refresher_rule.arn
}

# App Registry resources
resource "aws_servicecatalog_app_registry_application" "ta_spoke" {
  name        = "QM_TA-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
  description = "Service Catalog application to track and manage all your resources for the solution quota-monitor-for-aws"

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID     = "SO0005-TA"
    SolutionName   = "quota-monitor-for-aws"
    SolutionVersion = "v6.3.0"
  }
}

resource "aws_servicecatalog_app_registry_attribute_group" "ta_spoke" {
  name        = "QM_TA-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
  description = "Attribute group for application information"
  
  attributes = jsonencode({
    solutionID      = "SO0005-TA"
    solutionName    = "quota-monitor-for-aws"
    version         = "v6.3.0"
    applicationType = "AWS-Solutions"
  })

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID     = "SO0005-TA"
    SolutionName   = "quota-monitor-for-aws"
    SolutionVersion = "v6.3.0"
  }
}

resource "aws_servicecatalog_app_registry_attribute_group_association" "ta_spoke" {
  application_id     = aws_servicecatalog_app_registry_application.ta_spoke.id
  attribute_group_id = aws_servicecatalog_app_registry_attribute_group.ta_spoke.id
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Outputs
output "service_checks" {
  description = "service limit checks monitored in the account"
  value       = join(",", local.monitored_services)
}
