module "spoke" {
  source = "./modules/infrastructure"

  # Common
  create = true
  master_prefix = "QuotaMonitor"

  # Variables
  event_bus_arn = var.event_bus_arn
  ta_refresh_rate = var.ta_refresh_rate
  spoke_sns_region = var.spoke_sns_region
  notification_threshold = var.notification_threshold
  monitoring_frequency = var.monitoring_frequency
  report_ok_notifications = var.report_ok_notifications
  sagemaker_monitoring = var.sagemaker_monitoring
  connect_monitoring = var.connect_monitoring

  # Event Bus
  create_event = true
  event_buses = {
    sns_spoke = {
      name = "QuotaMonitorSnsSpokeBus"
    }
    sq_spoke = {
      name = "QuotaMonitorSpokeBus"
    }
  }

  event_bus_policies = {
    sns_spoke = {
      bus_name = module.spoke.event_bus_names["sns_spoke"]
      statements = [
        {
          sid = "allowed_accounts"
          effect = "Allow"
          principals = {
            AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
          }
          actions = ["events:PutEvents"]
          resources = [module.spoke.event_bus_arns["sns_spoke"]]
        }
      ]
    }
  }

  # Lambda Layer
  create_lambda_layer = true
  lambda_layers = {
    utils = {
      name = "QM-UtilsLayer"
      description = "Utilities layer for Quota Monitor"
      compatible_runtimes = ["nodejs18.x"]
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key = "quota-monitor-for-aws/v6.3.0/assete8b91b89616aa81e100a9f9ce53981ad5df4ba7439cebca83d5dc68349ed3703.zip"
      }
    }
  }

  # DynamoDB Tables
  create_dynamodb = true
  dynamodb_tables = {
    service = {
      name = "SQ-ServiceTable"
      hash_key = "ServiceCode"
      attributes = [
        {
          name = "ServiceCode"
          type = "S"
        }
      ]
      stream_enabled = true
      stream_view_type = "NEW_AND_OLD_IMAGES"
      point_in_time_recovery_enabled = true
      server_side_encryption_enabled = true
    }
    quota = {
      name = "SQ-QuotaTable"
      hash_key = "ServiceCode"
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

  # SSM Parameters
  create_ssm_parameter = true
  ssm_parameters = {
    notification_muting = {
      name = "/QuotaMonitor/spoke/NotificationConfiguration"
      type = "StringList"
      value = "NOP"
      description = "Muting configuration for services, limits e.g. ec2:L-1216C47A,ec2:Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances,dynamodb,logs:*,geo:L-05EFD12D"
    }
  }

  # SNS Topic
  create_sns = true
  sns_topics = {
    quota_monitor = {
      name = "QuotaMonitorSnsTopic"
      kms_master_key_id = "alias/aws/sns"
    }
  }

  # Lambda Functions
  create_lambda = true
  lambda_functions = {
    list_manager = {
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key = "quota-monitor-for-aws/v6.3.0/asset3701f2abae7e46f2ca278d27abfbafbf17499950bb5782fed31eb776c07ad072.zip"
      }
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 900
      memory_size = 256
      description = "SO0005 quota-monitor-for-aws - QM-ListManager-Function"
      layers = [module.spoke.lambda_layer_arns["utils"]]
      environment = {
        variables = {
          SQ_SERVICE_TABLE = module.spoke.dynamodb_table_ids["service"]
          SQ_QUOTA_TABLE = module.spoke.dynamodb_table_ids["quota"]
          PARTITION_KEY = "ServiceCode"
          SORT = "QuotaCode"
          LOG_LEVEL = "info"
          CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
          VERSION = "v6.3.0"
          SOLUTION_ID = "SO0005"
        }
      }
      event_source_mapping = {
        service_table = {
          event_source_arn = module.spoke.dynamodb_table_stream_arns["service"]
          batch_size = 1
          starting_position = "LATEST"
        }
      }
      event_invoke_config = {
        maximum_event_age_in_seconds = 14400
        qualifier = "$LATEST"
      }
      schedule = {
        expression = "rate(30 days)"
        name = "QM-ListManagerSchedule"
        description = "SO0005 quota-monitor-for-aws - quota-monitor-sq-spoke-EventsRule"
      }
    }
    sns_publisher = {
      name = "QM-SNSPublisher-Lambda"
      description = "SO0005 quota-monitor-for-aws - QM-SNSPublisher-Lambda"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 60
      memory_size = 128
      environment_variables = {
        QM_NOTIFICATION_MUTING_CONFIG_PARAMETER = module.spoke.ssm_parameter_names["notification_muting"]
        SEND_METRIC = "No"
        TOPIC_ARN = module.spoke.sns_topic_arns["quota_monitor"]
        LOG_LEVEL = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      dead_letter_config = {
        target_arn = module.spoke.sqs_queue_arns["sns_publisher_dlq"]
      }
      layers = [module.spoke.lambda_layer_arns["utils"]]
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key = "quota-monitor-for-aws/v6.3.0/assete7a324e67e467d0c22e13b0693ca4efdceb0d53025c7fb45fe524870a5c18046.zip"
      }
      event_invoke_config = {
        maximum_event_age_in_seconds = 14400
        qualifier = "$LATEST"
      }
      role_policies = {
        sns_publish = {
          actions = ["sns:Publish"]
          resources = [module.spoke.sns_topic_arns["quota_monitor"]]
        }
        kms = {
          actions = ["kms:GenerateDataKey"]
          resources = ["arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alias/aws/sns"]
        }
        ssm = {
          actions = ["ssm:GetParameter"]
          resources = [module.spoke.ssm_parameter_arns["notification_muting"]]
        }
        sqs = {
          actions = ["sqs:SendMessage"]
          resources = [module.spoke.sqs_queue_arns["sns_publisher_dlq"]]
        }
      }
    }
    ta_refresher = {
      name = "QM-TA-Refresher"
      description = "SO0005 quota-monitor-for-aws - QM-TA-Refresher-Lambda"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 60
      memory_size = 128
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key = "quota-monitor-for-aws/v6.3.0/assete062344a6a45f8d5d2900b99e0126935391d50d4577da563c08475673a012f4c.zip"
      }
      role_key = "ta_refresher_role"
      environment_variables = {
        AWS_SERVICES = "AutoScaling,CloudFormation,DynamoDB,EBS,EC2,ELB,IAM,Kinesis,RDS,Route53,SES,VPC"
        LOG_LEVEL = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      layers = [module.spoke.lambda_layer_arns["utils"]]
      dead_letter_config = {
        target_arn = module.spoke.sqs_queue_arns["ta_refresher_dlq"]
      }
      event_invoke_config = {
        maximum_event_age_in_seconds = 14400
        maximum_retry_attempts = 0
      }
    }
  }

  # Event Rules
  create_event_rule = true
  event_rules = {
    sns_publisher = {
      name = "QM-SNSPublisher-EventsRule"
      description = "SO0005 quota-monitor-for-aws - QM-SNSPublisher-EventsRule"
      event_bus_name = module.spoke.event_bus_names["sns_spoke"]
      event_pattern = jsonencode({
        source = ["aws.trustedadvisor", "aws-solutions.quota-monitor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification", "Service Quotas Utilization Notification"]
        detail = {
          status = ["WARN", "ERROR"]
        }
      })
      targets = [
        {
          arn = module.spoke.lambda_function_arns["sns_publisher"]
          target_id = "SNSPublisherTarget"
        }
      ]
    }
    ta_ok = {
      description = "Quota Monitor Solution - Spoke - Rule for TA OK events"
      event_pattern = jsonencode({
        account = [data.aws_caller_identity.current.account_id]
        source = ["aws.trustedadvisor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification"]
        detail = {
          status = ["OK"]
          check-item-detail = {
            Service = ["AutoScaling", "CloudFormation", "DynamoDB", "EBS", "EC2", "ELB", "IAM", "Kinesis", "RDS", "Route53", "SES", "VPC"]
          }
        }
      })
      targets = [{
        arn = var.event_bus_arn
        role_arn = module.spoke.iam_role_arns["ta_ok_events"]
      }]
    }
    ta_warn = {
      description = "Quota Monitor Solution - Spoke - Rule for TA WARN events"
      event_pattern = jsonencode({
        account = [data.aws_caller_identity.current.account_id]
        source = ["aws.trustedadvisor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification"]
        detail = {
          status = ["WARN"]
          check-item-detail = {
            Service = ["AutoScaling", "CloudFormation", "DynamoDB", "EBS", "EC2", "ELB", "IAM", "Kinesis", "RDS", "Route53", "SES", "VPC"]
          }
        }
      })
      targets = [{
        arn = var.event_bus_arn
        role_arn = module.spoke.iam_role_arns["ta_warn_events"]
      }]
    }
    ta_error = {
      description = "Quota Monitor Solution - Spoke - Rule for TA ERROR events"
      event_pattern = jsonencode({
        account = [data.aws_caller_identity.current.account_id]
        source = ["aws.trustedadvisor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification"]
        detail = {
          status = ["ERROR"]
          check-item-detail = {
            Service = ["AutoScaling", "CloudFormation", "DynamoDB", "EBS", "EC2", "ELB", "IAM", "Kinesis", "RDS", "Route53", "SES", "VPC"]
          }
        }
      })
      targets = [{
        arn = var.event_bus_arn
        role_arn = module.spoke.iam_role_arns["ta_error_events"]
      }]
    }
  }

  # SQS Queues
  create_sqs = true
  sqs_queues = {
    sns_publisher_dlq = {
      name = "QM-SNSPublisher-DLQ"
      kms_master_key_id = "alias/aws/sqs"
    }
    ta_refresher_dlq = {
      name = "QM-TA-Refresher-Lambda-Dead-Letter-Queue"
      kms_master_key_id = "alias/aws/sqs"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid = "DenyNonTLS"
          Effect = "Deny"
          Principal = "*"
          Action = "sqs:*"
          Resource = "*"
          Condition = {
            Bool = {
              "aws:SecureTransport": "false"
            }
          }
        }]
      })
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
              Effect = "Allow"
              Action = "sqs:SendMessage"
              Resource = module.spoke.sqs_queue_arns["ta_refresher_dlq"]
            },
            {
              Effect = "Allow"
              Action = "support:RefreshTrustedAdvisorCheck"
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
            Effect = "Allow"
            Action = "events:PutEvents"
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
            Effect = "Allow"
            Action = "events:PutEvents"
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
            Effect = "Allow"
            Action = "events:PutEvents"
            Resource = var.event_bus_arn
          }]
        })
      }
    }
  }

  # AppRegistry
  create_app_registry = true
  app_registry = {
    name = "QM-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
    description = "Service Catalog application to track and manage all your resources for the solution quota-monitor-for-aws"
  }

  app_registry_attribute_group = {
    name = "QM-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
    description = "Attribute group for application information"
    attributes = {
      solutionID = "SO0005"
      solutionName = "quota-monitor-for-aws"
      version = "v6.3.0"
      applicationType = "AWS-Solutions"
    }
  }

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID = "SO0005"
    SolutionName = "quota-monitor-for-aws"
    SolutionVersion = "v6.3.0"
  }
}

# Variables
variable "event_bus_arn" {
  type = string
  description = "Arn for the EventBridge bus in the monitoring account"
}

variable "spoke_sns_region" {
  type = string
  description = "Region in which the spoke SNS stack exists in this account"
  default = ""
}

variable "notification_threshold" {
  type = string
  description = "Threshold percentage for quota utilization alerts (0-100)"
  default = "80"
  validation {
    condition = can(regex("^([1-9]|[1-9][0-9])$", var.notification_threshold))
    error_message = "Threshold must be a whole number between 0 and 100"
  }
}

variable "monitoring_frequency" {
  type = string
  description = "Frequency to monitor quota utilization"
  default = "rate(12 hours)"
  validation {
    condition = contains(["rate(6 hours)", "rate(12 hours)", "rate(1 day)"], var.monitoring_frequency)
    error_message = "Monitoring frequency must be one of: rate(6 hours), rate(12 hours), rate(1 day)"
  }
}

variable "report_ok_notifications" {
  type = string
  description = "Report OK Notifications"
  default = "No"
  validation {
    condition = contains(["Yes", "No"], var.report_ok_notifications)
    error_message = "Value must be Yes or No"
  }
}

variable "sagemaker_monitoring" {
  type = string
  description = "Enable monitoring for SageMaker quotas"
  default = "Yes"
  validation {
    condition = contains(["Yes", "No"], var.sagemaker_monitoring)
    error_message = "Value must be Yes or No"
  }
}

variable "connect_monitoring" {
  type = string
  description = "Enable monitoring for Connect quotas"
  default = "Yes"
  validation {
    condition = contains(["Yes", "No"], var.connect_monitoring)
    error_message = "Value must be Yes or No"
  }
}

variable "ta_refresh_rate" {
  type = string
  description = "The rate at which to refresh Trusted Advisor checks"
  default = "rate(12 hours)"
  validation {
    condition = contains(["rate(6 hours)", "rate(12 hours)", "rate(1 day)"], var.ta_refresh_rate)
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
  value = "AutoScaling,CloudFormation,DynamoDB,EBS,EC2,ELB,IAM,Kinesis,RDS,Route53,SES,VPC"
}