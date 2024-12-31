module "sq_spoke" {
  source = "./modules/infrastructure"

  # Common
  create        = true
  master_prefix = "QuotaMonitor"

  # Variables
  event_bus_arn           = var.event_bus_arn
  spoke_sns_region        = var.spoke_sns_region
  notification_threshold  = var.notification_threshold
  monitoring_frequency    = var.monitoring_frequency
  report_ok_notifications = var.report_ok_notifications
  sagemaker_monitoring    = var.sagemaker_monitoring
  connect_monitoring      = var.connect_monitoring

  # Event Bus
  create_event = true
  event_buses = {
    sq_spoke = {
      name = "QuotaMonitorSpokeBus"
    }
  }

  # Lambda Layer
  create_lambda_layer = true
  lambda_layers = {
    utils = {
      name                = "QM-UtilsLayer-quota-monitor-sq-spoke"
      description         = "Utilities layer for Quota Monitor"
      compatible_runtimes = ["nodejs18.x"]
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key    = "quota-monitor-for-aws/v6.3.0/assete8b91b89616aa81e100a9f9ce53981ad5df4ba7439cebca83d5dc68349ed3703.zip"
      }
    }
  }

  # DynamoDB Tables
  create_dynamodb = true
  dynamodb_tables = {
    service = {
      name     = "SQ-ServiceTable"
      hash_key = "ServiceCode"
      attributes = [
        {
          name = "ServiceCode"
          type = "S"
        }
      ]
      stream_enabled                 = true
      stream_view_type               = "NEW_AND_OLD_IMAGES"
      point_in_time_recovery_enabled = true
      server_side_encryption_enabled = true
    }
    quota = {
      name      = "SQ-QuotaTable"
      hash_key  = "ServiceCode"
      range_key = "QuotaCode"
      attributes = [
        {
          name = "ServiceCode"
          type = "S"
        },
        {
          name = "QuotaCode"
          type = "S"
        }
      ]
      point_in_time_recovery_enabled = true
      server_side_encryption_enabled = true
    }
  }

  # Lambda Functions
  create_lambda = true
  lambda_functions = {
    list_manager = {
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key    = "quota-monitor-for-aws/v6.3.0/asset3701f2abae7e46f2ca278d27abfbafbf17499950bb5782fed31eb776c07ad072.zip"
      }
      handler     = "index.handler"
      runtime     = "nodejs18.x"
      timeout     = 900
      memory_size = 256
      description = "SO0005 quota-monitor-for-aws - QM-ListManager-Function"
      layers      = [module.sq_spoke.lambda_layer_arns["utils"]]
      environment = {
        variables = {
          SQ_SERVICE_TABLE      = module.sq_spoke.dynamodb_table_ids["service"]
          SQ_QUOTA_TABLE        = module.sq_spoke.dynamodb_table_ids["quota"]
          PARTITION_KEY         = "ServiceCode"
          SORT                  = "QuotaCode"
          LOG_LEVEL             = "info"
          CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
          VERSION               = "v6.3.0"
          SOLUTION_ID           = "SO0005"
        }
      }
      event_source_mapping = {
        service_table = {
          event_source_arn  = module.sq_spoke.dynamodb_table_stream_arns["service"]
          batch_size        = 1
          starting_position = "LATEST"
        }
      }
      event_invoke_config = {
        maximum_event_age_in_seconds = 14400
        qualifier                    = "$LATEST"
      }
      schedule = {
        expression  = "rate(30 days)"
        name        = "QM-ListManagerSchedule"
        description = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-EventsRule"
      }
      custom_role = true
      role_policies = [
        {
          name = "LambdaBasicExecution"
          policy = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Effect = "Allow"
                Action = [
                  "logs:CreateLogGroup",
                  "logs:CreateLogStream",
                  "logs:PutLogEvents"
                ]
                Resource = "arn:${data.aws_partition.current.partition}:logs:*:*:*"
              }
            ]
          })
        },
        {
          name = "DynamoDBAccess"
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
                  module.sq_spoke.dynamodb_table_arns["service"],
                  module.sq_spoke.dynamodb_table_arns["quota"]
                ]
              }
            ]
          })
        },
        {
          name = "ServiceQuotasAccess"
          policy = jsonencode({
            Version = "2012-10-17"
            Statement = [
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
              }
            ]
          })
        }
      ]
    }
    cw_poller = {
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key    = "quota-monitor-for-aws/v6.3.0/asset4ae69af36e954d598ae25d7f2f8f5ea5ecb93bf4ba61963aa7d8d571cf71ecce.zip"
      }
      handler     = "index.handler"
      runtime     = "nodejs18.x"
      timeout     = 900
      memory_size = 512
      description = "SO0005 quota-monitor-for-aws - QM-CWPoller-Lambda"
      layers      = [module.sq_spoke.lambda_layer_arns["utils"]]
      environment = {
        variables = {
          SQ_SERVICE_TABLE           = module.sq_spoke.dynamodb_table_ids["service"]
          SQ_QUOTA_TABLE             = module.sq_spoke.dynamodb_table_ids["quota"]
          SPOKE_EVENT_BUS            = module.sq_spoke.event_bus_names["sq_spoke"]
          POLLER_FREQUENCY           = var.monitoring_frequency
          THRESHOLD                  = var.notification_threshold
          SQ_REPORT_OK_NOTIFICATIONS = var.report_ok_notifications
          LOG_LEVEL                  = "info"
          CUSTOM_SDK_USER_AGENT      = "AwsSolution/SO0005/v6.3.0"
          VERSION                    = "v6.3.0"
          SOLUTION_ID                = "SO0005"
        }
      }
      dead_letter_config = {
        target_arn = module.sq_spoke.sqs_queue_arns["cw_poller_dlq"]
      }
      event_invoke_config = {
        maximum_event_age_in_seconds = 14400
        qualifier                    = "$LATEST"
      }
      schedule = {
        expression  = var.monitoring_frequency
        name        = "QM-CWPoller-EventsRule"
        description = "SO0005 quota-monitor-for-aws - QM-CWPoller-EventsRule"
      }
      custom_role = true
      role_policies = [
        {
          name = "LambdaBasicExecution"
          policy = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Effect = "Allow"
                Action = [
                  "logs:CreateLogGroup",
                  "logs:CreateLogStream",
                  "logs:PutLogEvents"
                ]
                Resource = "arn:${data.aws_partition.current.partition}:logs:*:*:*"
              }
            ]
          })
        },
        {
          name = "DynamoDBAccess"
          policy = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Effect = "Allow"
                Action = [
                  "dynamodb:Query",
                  "dynamodb:Scan"
                ]
                Resource = [
                  module.sq_spoke.dynamodb_table_arns["service"],
                  module.sq_spoke.dynamodb_table_arns["quota"]
                ]
              }
            ]
          })
        },
        {
          name = "EventBridgeAccess"
          policy = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Effect   = "Allow"
                Action   = "events:PutEvents"
                Resource = module.sq_spoke.event_bus_arns["sq_spoke"]
              }
            ]
          })
        },
        {
          name = "ServiceQuotasAccess"
          policy = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Effect = "Allow"
                Action = [
                  "cloudwatch:GetMetricData",
                  "servicequotas:ListServices"
                ]
                Resource = "*"
              }
            ]
          })
        },
        {
          name = "SQSAccess"
          policy = jsonencode({
            Version = "2012-10-17"
            Statement = [
              {
                Effect   = "Allow"
                Action   = "sqs:SendMessage"
                Resource = module.sq_spoke.sqs_queue_arns["cw_poller_dlq"]
              }
            ]
          })
        }
      ]
    }
  }

  # SQS Queues
  create_sqs = true
  sqs_queues = {
    cw_poller_dlq = {
      name              = "QM-CWPoller-Lambda-Dead-Letter-Queue"
      kms_master_key_id = "alias/aws/sqs"
    }
  }

  sqs_queue_policies = {
    cw_poller_dlq = {
      queue_key = "cw_poller_dlq"
      statements = [
        {
          sid    = "DenyNonSecureTransport"
          effect = "Deny"
          principals = {
            AWS = "*"
          }
          actions   = ["sqs:*"]
          resources = [module.sq_spoke.sqs_queue_arns["cw_poller_dlq"]]
          conditions = {
            Bool = {
              "aws:SecureTransport" = "false"
            }
          }
        }
      ]
    }
  }

  # Event Rules
  create_event_rule = true
  event_rules = {
    utilization_ok = {
      description    = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-EventsRule"
      event_bus_name = module.sq_spoke.event_bus_names["sq_spoke"]
      event_pattern = {
        account     = [data.aws_caller_identity.current.account_id]
        source      = ["aws-solutions.quota-monitor"]
        detail-type = ["Service Quotas Utilization Notification"]
        detail = {
          status = ["OK"]
        }
      }
      targets = [{
        arn      = var.event_bus_arn
        role_arn = module.sq_spoke.iam_role_arns["utilization_ok_events"]
      }]
    }
    utilization_warn = {
      description    = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-EventsRule"
      event_bus_name = module.sq_spoke.event_bus_names["sq_spoke"]
      event_pattern = {
        account     = [data.aws_caller_identity.current.account_id]
        source      = ["aws-solutions.quota-monitor"]
        detail-type = ["Service Quotas Utilization Notification"]
        detail = {
          status = ["WARN"]
        }
      }
      targets = [{
        arn      = var.event_bus_arn
        role_arn = module.sq_spoke.iam_role_arns["utilization_warn_events"]
      }]
    }
    utilization_error = {
      description    = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-EventsRule"
      event_bus_name = module.sq_spoke.event_bus_names["sq_spoke"]
      event_pattern = {
        account     = [data.aws_caller_identity.current.account_id]
        source      = ["aws-solutions.quota-monitor"]
        detail-type = ["Service Quotas Utilization Notification"]
        detail = {
          status = ["ERROR"]
        }
      }
      targets = [{
        arn      = var.event_bus_arn
        role_arn = module.sq_spoke.iam_role_arns["utilization_error_events"]
      }]
    }
    spoke_sns = {
      description    = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-SpokeSnsEventsRule"
      event_bus_name = module.sq_spoke.event_bus_names["sq_spoke"]
      event_pattern = {
        source      = ["aws.trustedadvisor", "aws-solutions.quota-monitor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification", "Service Quotas Utilization Notification"]
        detail = {
          status = ["WARN", "ERROR"]
        }
      }
      targets = [{
        arn      = "arn:${data.aws_partition.current.partition}:events:${var.spoke_sns_region}:${data.aws_caller_identity.current.account_id}:event-bus/QuotaMonitorSnsSpokeBus"
        role_arn = module.sq_spoke.iam_role_arns["spoke_sns_events"]
      }]
      is_enabled = var.spoke_sns_region != ""
    }
  }

  # IAM Roles for Event Rules
  create_iam = true
  iam_roles = {
    utilization_ok_events = {
      name = "QM-Utilization-OK-Events"
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
      policies = [{
        name = "EventBridgePutEvents"
        policy = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect   = "Allow"
            Action   = "events:PutEvents"
            Resource = var.event_bus_arn
          }]
        })
      }]
    }
    utilization_warn_events = {
      name = "QM-Utilization-Warn-Events"
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
      policies = [{
        name = "EventBridgePutEvents"
        policy = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect   = "Allow"
            Action   = "events:PutEvents"
            Resource = var.event_bus_arn
          }]
        })
      }]
    }
    utilization_error_events = {
      name = "QM-Utilization-Error-Events"
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
      policies = [{
        name = "EventBridgePutEvents"
        policy = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect   = "Allow"
            Action   = "events:PutEvents"
            Resource = var.event_bus_arn
          }]
        })
      }]
    }
    spoke_sns_events = {
      name = "QM-SpokeSns-Events"
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
      policies = [{
        name = "EventBridgePutEvents"
        policy = jsonencode({
          Version = "2012-10-17"
          Statement = [{
            Effect   = "Allow"
            Action   = "events:PutEvents"
            Resource = "arn:${data.aws_partition.current.partition}:events:${var.spoke_sns_region}:${data.aws_caller_identity.current.account_id}:event-bus/QuotaMonitorSnsSpokeBus"
          }]
        })
      }]
    }
  }

  # AppRegistry
  create_app_registry = true
  app_registry = {
    name        = "QM_SQ-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
    description = "Service Catalog application to track and manage all your resources for the solution quota-monitor-for-aws"
  }

  app_registry_attribute_group = {
    name        = "QM_SQ-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
    description = "Attribute group for application information"
    attributes = {
      solutionID      = "SO0005-SQ"
      solutionName    = "quota-monitor-for-aws"
      version         = "v6.3.0"
      applicationType = "AWS-Solutions"
    }
  }

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID      = "SO0005-SQ"
    SolutionName    = "quota-monitor-for-aws"
    SolutionVersion = "v6.3.0"
  }
}

# Variables
variable "event_bus_arn" {
  type        = string
  description = "Arn for the EventBridge bus in the monitoring account"
}

variable "spoke_sns_region" {
  type        = string
  description = "Region in which the spoke SNS stack exists in this account"
  default     = ""
}

variable "notification_threshold" {
  type        = string
  description = "Threshold percentage for quota utilization alerts (0-100)"
  default     = "80"
  validation {
    condition     = can(regex("^([1-9]|[1-9][0-9])$", var.notification_threshold))
    error_message = "Threshold must be a whole number between 0 and 100"
  }
}

variable "monitoring_frequency" {
  type        = string
  description = "Frequency to monitor quota utilization"
  default     = "rate(12 hours)"
  validation {
    condition     = contains(["rate(6 hours)", "rate(12 hours)", "rate(1 day)"], var.monitoring_frequency)
    error_message = "Monitoring frequency must be one of: rate(6 hours), rate(12 hours), rate(1 day)"
  }
}

variable "report_ok_notifications" {
  type        = string
  description = "Report OK Notifications"
  default     = "No"
  validation {
    condition     = contains(["Yes", "No"], var.report_ok_notifications)
    error_message = "Value must be Yes or No"
  }
}

variable "sagemaker_monitoring" {
  type        = string
  description = "Enable monitoring for SageMaker quotas"
  default     = "Yes"
  validation {
    condition     = contains(["Yes", "No"], var.sagemaker_monitoring)
    error_message = "Value must be Yes or No"
  }
}

variable "connect_monitoring" {
  type        = string
  description = "Enable monitoring for Connect quotas"
  default     = "Yes"
  validation {
    condition     = contains(["Yes", "No"], var.connect_monitoring)
    error_message = "Value must be Yes or No"
  }
}

# Data sources
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {} 