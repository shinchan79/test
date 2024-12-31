module "ta_spoke" {
  source = "./modules/infrastructure"

  # Common
  create        = true
  master_prefix = "QuotaMonitor"

  # Variables
  event_bus_arn   = var.event_bus_arn
  ta_refresh_rate = var.ta_refresh_rate

  # Lambda Layer
  create_lambda_layer = true
  lambda_layers = {
    utils = {
      name                = "QM-UtilsLayer"
      description         = "Utilities layer for Quota Monitor"
      compatible_runtimes = ["nodejs18.x"]
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key    = "quota-monitor-for-aws/v6.3.0/assete8b91b89616aa81e100a9f9ce53981ad5df4ba7439cebca83d5dc68349ed3703.zip"
      }
    }
  }

  # Lambda Function
  create_lambda = true
  lambda_functions = {
    ta_refresher = {
      name        = "QM-TA-Refresher"
      description = "SO0005 quota-monitor-for-aws - QM-TA-Refresher-Lambda"
      handler     = "index.handler"
      runtime     = "nodejs18.x"
      timeout     = 60
      memory_size = 128
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key    = "quota-monitor-for-aws/v6.3.0/assete062344a6a45f8d5d2900b99e0126935391d50d4577da563c08475673a012f4c.zip"
      }
      role_key = "ta_refresher_role"
      environment_variables = {
        AWS_SERVICES          = "AutoScaling,CloudFormation,DynamoDB,EBS,EC2,ELB,IAM,Kinesis,RDS,Route53,SES,VPC"
        LOG_LEVEL             = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION               = "v6.3.0"
        SOLUTION_ID           = "SO0005"
      }
      layers = [module.ta_spoke.lambda_layer_arns["utils"]]
      dead_letter_config = {
        target_arn = module.ta_spoke.sqs_queue_arns["ta_refresher_dlq"]
      }
      event_invoke_config = {
        maximum_event_age_in_seconds = 14400
        maximum_retry_attempts       = 0
      }
    }
  }

  # Event Rules
  create_event_rule = true
  event_rules = {
    ta_ok = {
      description = "Quota Monitor Solution - Spoke - Rule for TA OK events"
      event_pattern = jsonencode({
        account     = [data.aws_caller_identity.current.account_id]
        source      = ["aws.trustedadvisor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification"]
        detail = {
          status = ["OK"]
          check-item-detail = {
            Service = ["AutoScaling", "CloudFormation", "DynamoDB", "EBS", "EC2", "ELB", "IAM", "Kinesis", "RDS", "Route53", "SES", "VPC"]
          }
        }
      })
      targets = [{
        arn      = var.event_bus_arn
        role_arn = module.ta_spoke.iam_role_arns["ta_ok_events"]
      }]
    }
    ta_warn = {
      description = "Quota Monitor Solution - Spoke - Rule for TA WARN events"
      event_pattern = jsonencode({
        account     = [data.aws_caller_identity.current.account_id]
        source      = ["aws.trustedadvisor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification"]
        detail = {
          status = ["WARN"]
          check-item-detail = {
            Service = ["AutoScaling", "CloudFormation", "DynamoDB", "EBS", "EC2", "ELB", "IAM", "Kinesis", "RDS", "Route53", "SES", "VPC"]
          }
        }
      })
      targets = [{
        arn      = var.event_bus_arn
        role_arn = module.ta_spoke.iam_role_arns["ta_warn_events"]
      }]
    }
    ta_error = {
      description = "Quota Monitor Solution - Spoke - Rule for TA ERROR events"
      event_pattern = jsonencode({
        account     = [data.aws_caller_identity.current.account_id]
        source      = ["aws.trustedadvisor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification"]
        detail = {
          status = ["ERROR"]
          check-item-detail = {
            Service = ["AutoScaling", "CloudFormation", "DynamoDB", "EBS", "EC2", "ELB", "IAM", "Kinesis", "RDS", "Route53", "SES", "VPC"]
          }
        }
      })
      targets = [{
        arn      = var.event_bus_arn
        role_arn = module.ta_spoke.iam_role_arns["ta_error_events"]
      }]
    }
  }

  # IAM Roles
  create_iam = true
  iam_roles = {
    ta_refresher_role = {
      name = "QM-TA-Refresher-Role"
      assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Action = "sts:AssumeRole"
          Effect = "Allow"
          Principal = {
            Service = "lambda.amazonaws.com"
          }
        }]
      })
      managed_policy_arns = [
        "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
      ]
      policies = {
        ta_refresher = jsonencode({
          Version = "2012-10-17"
          Statement = [
            {
              Effect   = "Allow"
              Action   = "sqs:SendMessage"
              Resource = module.ta_spoke.sqs_queue_arns["ta_refresher_dlq"]
            },
            {
              Effect   = "Allow"
              Action   = "support:RefreshTrustedAdvisorCheck"
              Resource = "*"
            }
          ]
        })
      }
    }
    ta_ok_events = {
      name = "QM-TA-OK-Events-Role"
      assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Action = "sts:AssumeRole"
          Effect = "Allow"
          Principal = {
            Service = "events.amazonaws.com"
          }
        }]
      })
      policies = {
        events = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect   = "Allow"
            Action   = "events:PutEvents"
            Resource = var.event_bus_arn
          }]
        })
      }
    }
    ta_warn_events = {
      name = "QM-TA-Warn-Events-Role"
      assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Action = "sts:AssumeRole"
          Effect = "Allow"
          Principal = {
            Service = "events.amazonaws.com"
          }
        }]
      })
      policies = {
        events = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect   = "Allow"
            Action   = "events:PutEvents"
            Resource = var.event_bus_arn
          }]
        })
      }
    }
    ta_error_events = {
      name = "QM-TA-Error-Events-Role"
      assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Action = "sts:AssumeRole"
          Effect = "Allow"
          Principal = {
            Service = "events.amazonaws.com"
          }
        }]
      })
      policies = {
        events = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect   = "Allow"
            Action   = "events:PutEvents"
            Resource = var.event_bus_arn
          }]
        })
      }
    }
  }

  # SQS Queue
  create_sqs = true
  sqs_queues = {
    ta_refresher_dlq = {
      name              = "QM-TA-Refresher-Lambda-Dead-Letter-Queue"
      kms_master_key_id = "alias/aws/sqs"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid       = "DenyNonTLS"
          Effect    = "Deny"
          Principal = "*"
          Action    = "sqs:*"
          Resource  = "*"
          Condition = {
            Bool = {
              "aws:SecureTransport" : "false"
            }
          }
        }]
      })
    }
  }

  # AppRegistry
  create_app_registry = true
  app_registry = {
    enabled     = true
    name        = "QM_TA-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
    description = "Service Catalog application to track and manage all your resources for the solution quota-monitor-for-aws"
  }

  app_registry_attribute_group = {
    name        = "QM_TA-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
    description = "Attribute group for application information"
    attributes = {
      solutionID      = "SO0005-TA"
      solutionName    = "quota-monitor-for-aws"
      version         = "v6.3.0"
      applicationType = "AWS-Solutions"
    }
  }

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID      = "SO0005-TA"
    SolutionName    = "quota-monitor-for-aws"
    SolutionVersion = "v6.3.0"
  }
}

# Variables
variable "event_bus_arn" {
  type        = string
  description = "Arn for the EventBridge bus in the monitoring account"
}

variable "ta_refresh_rate" {
  type        = string
  description = "The rate at which to refresh Trusted Advisor checks"
  default     = "rate(12 hours)"
  validation {
    condition     = contains(["rate(6 hours)", "rate(12 hours)", "rate(1 day)"], var.ta_refresh_rate)
    error_message = "Refresh rate must be one of: rate(6 hours), rate(12 hours), rate(1 day)"
  }
}

# Data sources
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Outputs
output "service_checks" {
  description = "service limit checks monitored in the account"
  value       = "AutoScaling,CloudFormation,DynamoDB,EBS,EC2,ELB,IAM,Kinesis,RDS,Route53,SES,VPC"
}
