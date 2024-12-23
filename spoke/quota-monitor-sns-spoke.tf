# Provider Configuration
provider "aws" {
  region = "us-east-1"
}

# Local Variables
locals {
  solution_id      = "SO0005-SPOKE-SNS"
  version          = "v6.3.0"
  solution_name    = "quota-monitor-for-aws"
  ssm_parameters = {
    notification_muting_config = "/QuotaMonitor/spoke/NotificationConfiguration"
  }
}

# Data Sources
data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# EventBus
resource "aws_cloudwatch_event_bus" "sns_spoke" {
  name = "QuotaMonitorSnsSpokeBus"
}

resource "aws_cloudwatch_event_bus_policy" "sns_spoke" {
  event_bus_name = aws_cloudwatch_event_bus.sns_spoke.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "allowed_accounts"
        Effect    = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action    = "events:PutEvents"
        Resource  = aws_cloudwatch_event_bus.sns_spoke.arn
      }
    ]
  })
}

# Lambda Layer
resource "aws_lambda_layer_version" "utils" {
  filename            = "lambda-layer.zip"  # You'll need to provide the actual layer code
  layer_name          = "QM-UtilsLayer-quota-monitor-sns-spoke"
  compatible_runtimes = ["nodejs18.x"]
  
  source_code_hash = filebase64sha256("lambda-layer.zip")
}

# SSM Parameter
resource "aws_ssm_parameter" "notification_muting_config" {
  name        = local.ssm_parameters.notification_muting_config
  description = "Muting configuration for services, limits"
  type        = "StringList"
  value       = "NOP"
}

# SNS Topic
resource "aws_sns_topic" "publisher" {
  name              = "quota-monitor-sns-spoke-topic"
  kms_master_key_id = "alias/aws/sns"
}

# Dead Letter Queue
resource "aws_sqs_queue" "publisher_dlq" {
  name              = "quota-monitor-sns-spoke-publisher-dlq"
  kms_master_key_id = "alias/aws/sqs"
}

resource "aws_sqs_queue_policy" "publisher_dlq" {
  queue_url = aws_sqs_queue.publisher_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = "sqs:*"
        Resource = aws_sqs_queue.publisher_dlq.arn
        Condition = {
          Bool = {
            "aws:SecureTransport": "false"
          }
        }
      }
    ]
  })
}

# IAM Role for Lambda
resource "aws_iam_role" "publisher" {
  name = "quota-monitor-sns-spoke-publisher"

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

resource "aws_iam_role_policy" "publisher" {
  name = "quota-monitor-sns-spoke-publisher-policy"
  role = aws_iam_role.publisher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.publisher_dlq.arn
      },
      {
        Effect = "Allow"
        Action = "SNS:Publish"
        Resource = aws_sns_topic.publisher.arn
      },
      {
        Effect = "Allow"
        Action = "kms:GenerateDataKey"
        Resource = "arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alias/aws/sns"
      },
      {
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = aws_ssm_parameter.notification_muting_config.arn
      }
    ]
  })
}

# Lambda Function
resource "aws_lambda_function" "publisher" {
  filename         = "publisher.zip"  # You'll need to provide the actual function code
  function_name    = "quota-monitor-sns-spoke-publisher"
  role            = aws_iam_role.publisher.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 60
  memory_size     = 128

  dead_letter_config {
    target_arn = aws_sqs_queue.publisher_dlq.arn
  }

  environment {
    variables = {
      QM_NOTIFICATION_MUTING_CONFIG_PARAMETER = aws_ssm_parameter.notification_muting_config.name
      SEND_METRIC                            = "No"
      TOPIC_ARN                              = aws_sns_topic.publisher.arn
      LOG_LEVEL                              = "info"
      CUSTOM_SDK_USER_AGENT                  = "AwsSolution/${local.solution_id}/${local.version}"
      VERSION                                = local.version
      SOLUTION_ID                            = local.solution_id
    }
  }

  layers = [aws_lambda_layer_version.utils.arn]
}

resource "aws_lambda_function_event_invoke_config" "publisher" {
  function_name                = aws_lambda_function.publisher.function_name
  maximum_event_age_in_seconds = 14400
  qualifier                    = "$LATEST"
}

# EventBridge Rule
resource "aws_cloudwatch_event_rule" "publisher" {
  name            = "quota-monitor-sns-spoke-publisher"
  description     = "SO0005 quota-monitor-for-aws - sq-spoke-SNSPublisherFunction-EventsRule"
  event_bus_name  = aws_cloudwatch_event_bus.sns_spoke.name

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
}

resource "aws_cloudwatch_event_target" "publisher" {
  rule      = aws_cloudwatch_event_rule.publisher.name
  target_id = "SNSPublisherLambda"
  arn       = aws_lambda_function.publisher.arn
  event_bus_name = aws_cloudwatch_event_bus.sns_spoke.name
}

resource "aws_lambda_permission" "publisher" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.publisher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.publisher.arn
}

# AppRegistry Application
resource "aws_servicecatalog_app_registry_application" "spoke_sns" {
  name        = "${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
  description = "Service Catalog application to track and manage all your resources for the solution quota-monitor-for-aws"

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID     = local.solution_id
    SolutionName   = local.solution_name
    SolutionVersion = local.version
  }
}

resource "aws_servicecatalog_app_registry_attribute_group" "spoke_sns" {
  name        = "${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
  description = "Attribute group for application information"

  attributes = jsonencode({
    solutionID      = local.solution_id
    solutionName    = local.solution_name
    version         = local.version
    applicationType = "AWS-Solutions"
  })

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID     = local.solution_id
    SolutionName   = local.solution_name
    SolutionVersion = local.version
  }
}

resource "aws_servicecatalog_app_registry_attribute_group_association" "spoke_sns" {
  application_id     = aws_servicecatalog_app_registry_application.spoke_sns.id
  attribute_group_id = aws_servicecatalog_app_registry_attribute_group.spoke_sns.id
}

resource "aws_servicecatalog_app_registry_resource_association" "spoke_sns" {
  application_id = aws_servicecatalog_app_registry_application.spoke_sns.id
  resource_arn   = "arn:${data.aws_partition.current.partition}:cloudformation:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:stack/${local.solution_id}/*"
  resource_type  = "CFN_STACK"
}

# Outputs
output "spoke_sns_event_bus_arn" {
  description = "SNS Event Bus Arn in spoke account"
  value       = aws_cloudwatch_event_bus.sns_spoke.arn
}
