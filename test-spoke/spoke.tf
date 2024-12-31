module "spoke" {
  source = "../modules/infrastructure"

  # Common
  create = true
  master_prefix = "QuotaMonitor"

  # Event Buses
  create_event = true
  event_buses = {
    sns_spoke = {
      name = "QuotaMonitorSnsSpokeBus"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid = "allowed_accounts"
            Effect = "Allow"
            Principal = {
              AWS = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
            }
            Action = ["events:PutEvents"]
            Resource = "*"
          }
        ]
      })
    }
    sq_spoke = {
      name = "QuotaMonitorSpokeBus"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid = "allowed_accounts"
            Effect = "Allow"
            Principal = {
              AWS = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
            }
            Action = ["events:PutEvents"]
            Resource = "*"
          }
        ]
      })
    }
  }

  # Event Rules
  event_rules = {
    ta_ok = {
      name = "QuotaMonitor-TAOkRule"
      description = "SO0005 quota-monitor-for-aws - Rule for TA OK events"
      event_pattern = jsonencode({
        account = [data.aws_caller_identity.current.account_id]
        detail = {
          status = ["OK"]
          check-item-detail = {
            Service = ["AutoScaling", "CloudFormation", "DynamoDB", "EBS", "EC2", "ELB", "IAM", "Kinesis", "RDS", "Route53", "SES", "VPC"]
          }
        }
        detail-type = ["Trusted Advisor Check Item Refresh Notification"]
        source = ["aws.trustedadvisor"]
      })
    }
    ta_warn = {
      name = "QuotaMonitor-TAWarnRule"
      description = "SO0005 quota-monitor-for-aws - Rule for TA WARN events"
      event_pattern = jsonencode({
        account = [data.aws_caller_identity.current.account_id]
        detail = {
          status = ["WARN"]
          check-item-detail = {
            Service = ["AutoScaling", "CloudFormation", "DynamoDB", "EBS", "EC2", "ELB", "IAM", "Kinesis", "RDS", "Route53", "SES", "VPC"]
          }
        }
        detail-type = ["Trusted Advisor Check Item Refresh Notification"]
        source = ["aws.trustedadvisor"]
      })
    }
    ta_error = {
      name = "QuotaMonitor-TAErrorRule"
      description = "SO0005 quota-monitor-for-aws - Rule for TA ERROR events"
      event_pattern = jsonencode({
        account = [data.aws_caller_identity.current.account_id]
        detail = {
          status = ["ERROR"]
          check-item-detail = {
            Service = ["AutoScaling", "CloudFormation", "DynamoDB", "EBS", "EC2", "ELB", "IAM", "Kinesis", "RDS", "Route53", "SES", "VPC"]
          }
        }
        detail-type = ["Trusted Advisor Check Item Refresh Notification"]
        source = ["aws.trustedadvisor"]
      })
    }
    sns_publisher = {
      name = "QuotaMonitor-SNSPublisherRule"
      description = "SO0005 quota-monitor-for-aws - Rule for SNS Publisher"
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
  }

  # Event Targets
  event_targets = {
    ta_ok = {
      rule = "QuotaMonitor-TAOkRule"
      target_arn = var.event_bus_arn
      role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/TAOkRuleEventsRole"
    }
    ta_warn = {
      rule = "QuotaMonitor-TAWarnRule" 
      target_arn = var.event_bus_arn
      role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/TAWarnRuleEventsRole"
    }
    ta_error = {
      rule = "QuotaMonitor-TAErrorRule"
      target_arn = var.event_bus_arn
      role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/TAErrorRuleEventsRole"
    }
    sns_publisher = {
      rule = "QuotaMonitor-SNSPublisherRule"
      target_arn = "arn:${data.aws_partition.current.partition}:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:QuotaMonitor-SNSPublisher"
    }
  }

  # Event Schedules
  event_schedules = {
    ta_refresher = {
      name = "QuotaMonitor-TARefresher"
      schedule_expression = var.ta_refresh_rate
      flexible_time_window = "OFF"
      role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/TARefresherRole"
      input = jsonencode({
        source = "aws.quotamonitor"
        detail-type = "Quota Monitor TA Refresh"
        detail = {
          action = "refresh"
        }
      })
    }
  }

  # Lambda Layers
  create_lambda_layer = true
  lambda_layers = {
    utils_sns = {
      name = "QM-UtilsLayer-quota-monitor-sns-spoke"
      description = "Utilities layer for Quota Monitor SNS"
      compatible_runtimes = ["nodejs18.x"]
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key = "quota-monitor-for-aws/v6.3.0/assete8b91b89616aa81e100a9f9ce53981ad5df4ba7439cebca83d5dc68349ed3703.zip"
      }
    }
    utils_sq = {
      name = "QM-UtilsLayer-quota-monitor-sq-spoke"
      description = "Utilities layer for Quota Monitor SQ"
      compatible_runtimes = ["nodejs18.x"]
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key = "quota-monitor-for-aws/v6.3.0/assete8b91b89616aa81e100a9f9ce53981ad5df4ba7439cebca83d5dc68349ed3703.zip"
      }
    }
    utils_ta = {
      name = "QM-UtilsLayer"
      description = "Utilities layer for Quota Monitor TA"
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
    service_table = {
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
      server_side_encryption = {
        enabled = true
      }
    }
    quota_table = {
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
      server_side_encryption = {
        enabled = true
      }
    }
  }

  # SSM Parameters
  create_ssm_parameter = true
  ssm_parameters = {
    notification_muting = {
      name = "/QuotaMonitor/spoke/NotificationConfiguration"
      description = "Muting configuration for services, limits"
      type = "StringList"
      value = "NOP"
      tier = "Standard"
    }
  }

  # SNS Topics
  create_sns = true
  sns_topic = {
    publisher = {
      name = "QuotaMonitor-SNSPublisher"
      kms_master_key_id = "alias/aws/sns"
    }
  }

  # SQS Queues
  create_sqs = true
  sqs_queue = {
    sns_publisher_dlq = {
      name = "QuotaMonitor-SNSPublisher-DLQ"
      kms_master_key_id = "alias/aws/sqs"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect = "Deny"
            Principal = "*"
            Action = "sqs:*"
            Resource = "*"
            Condition = {
              Bool = {
                "aws:SecureTransport": "false"
              }
            }
          }
        ]
      })
    }
    ta_refresher_dlq = {
      name = "QuotaMonitor-TARefresher-DLQ"
      kms_master_key_id = "alias/aws/sqs"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect = "Deny"
            Principal = "*"
            Action = "sqs:*"
            Resource = "*"
            Condition = {
              Bool = {
                "aws:SecureTransport": "false"
              }
            }
          }
        ]
      })
    }
    list_manager_dlq = {
      name = "QuotaMonitor-ListManager-DLQ"
      kms_master_key_id = "alias/aws/sqs"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect = "Deny"
            Principal = "*"
            Action = "sqs:*"
            Resource = "*"
            Condition = {
              Bool = {
                "aws:SecureTransport": "false"
              }
            }
          }
        ]
      })
    }
  }

  # Lambda Functions
  # lambda_functions = {
  #   sns_publisher = {
  #     name = "QuotaMonitor-SNSPublisher"
  #     description = "SO0005 quota-monitor-for-aws - SNS Publisher Function"
  #     handler = "index.handler"
  #     runtime = "nodejs18.x"
  #     timeout = 60
  #     memory_size = 128
  #     layers = ["utils_sns"]
  #     source_dir = "../lambda_sources/sns-publisher"
  #     environment_variables = {
  #       LOG_LEVEL = "info"
  #       QM_NOTIFICATION_MUTING_CONFIG_PARAMETER = "/QuotaMonitor/spoke/NotificationConfiguration"
  #       SEND_METRIC = "No"
  #       TOPIC_ARN = "arn:${data.aws_partition.current.partition}:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:QuotaMonitor-SNSPublisher"
  #       CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
  #       VERSION = "v6.3.0"
  #       SOLUTION_ID = "SO0005"
  #     }
  #     dead_letter_config = {
  #       target_arn = "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:QuotaMonitor-SNSPublisher-DLQ"
  #     }
  #     logging_config = {
  #       log_format = "Text"
  #       retention_in_days = 7
  #     }
  #   }
    
  #   list_manager = {
  #     name = "QuotaMonitor-ListManager"
  #     description = "SO0005 quota-monitor-for-aws - List Manager Function"
  #     handler = "index.handler"
  #     runtime = "nodejs18.x"
  #     timeout = 60
  #     memory_size = 128
  #     layers = ["utils_sq"]
  #     source_dir = "../lambda_sources/list-manager"
  #     environment_variables = {
  #       LOG_LEVEL = "info"
  #       CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
  #       VERSION = "v6.3.0"
  #       SOLUTION_ID = "SO0005"
  #     }
  #     dead_letter_config = {
  #       target_arn = "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:QuotaMonitor-ListManager-DLQ"
  #     }
  #     logging_config = {
  #       log_format = "Text"
  #       retention_in_days = 7
  #     }
  #   }
    
  #   ta_refresher = {
  #     name = "QuotaMonitor-TARefresher"
  #     description = "SO0005 quota-monitor-for-aws - TA Refresher Function"
  #     handler = "index.handler"
  #     runtime = "nodejs18.x"
  #     timeout = 60
  #     memory_size = 128
  #     layers = ["utils_ta"]
  #     source_dir = "../lambda_sources/ta-refresher"
  #     environment_variables = {
  #       LOG_LEVEL = "info"
  #       AWS_SERVICES = "AutoScaling,CloudFormation,DynamoDB,EBS,EC2,ELB,IAM,Kinesis,RDS,Route53,SES,VPC"
  #       CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
  #       VERSION = "v6.3.0"
  #       SOLUTION_ID = "SO0005"
  #     }
  #     dead_letter_config = {
  #       target_arn = "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:QuotaMonitor-TARefresher-DLQ"
  #     }
  #     logging_config = {
  #       log_format = "Text"
  #       retention_in_days = 7
  #     }
  #   }
  # }
    # Lambda Functions
  create_lambda = true
  lambda_functions = {
    sns_publisher = {
      name = "QuotaMonitor-SNSPublisher"
      description = "SO0005 quota-monitor-for-aws - SNS Publisher Function"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 60
      memory_size = 128
      layers = ["utils_sns"]
      s3_bucket = "solutions-${data.aws_region.current.name}"
      s3_key = "quota-monitor-for-aws/v6.3.0/assete7a324e67e467d0c22e13b0693ca4efdceb0d53025c7fb45fe524870a5c18046.zip"
      environment_variables = {
        LOG_LEVEL = "info"
        QM_NOTIFICATION_MUTING_CONFIG_PARAMETER = "/QuotaMonitor/spoke/NotificationConfiguration"
        SEND_METRIC = "No"
        TOPIC_ARN = "arn:${data.aws_partition.current.partition}:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:QuotaMonitor-SNSPublisher"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      dead_letter_config = {
        target_arn = "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:QuotaMonitor-SNSPublisher-DLQ"
      }
      logging_config = {
        log_format = "Text"
        retention_in_days = 7
      }
    }
    
    list_manager = {
      name = "QuotaMonitor-ListManager"
      description = "SO0005 quota-monitor-for-aws - List Manager Function"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 60
      memory_size = 128
      layers = ["utils_sq"]
      s3_bucket = "solutions-${data.aws_region.current.name}"
      s3_key = "quota-monitor-for-aws/v6.3.0/assete7a324e67e467d0c22e13b0693ca4efdceb0d53025c7fb45fe524870a5c18046.zip"
      environment_variables = {
        LOG_LEVEL = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      dead_letter_config = {
        target_arn = "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:QuotaMonitor-ListManager-DLQ"
      }
      logging_config = {
        log_format = "Text"
        retention_in_days = 7
      }
    }
    
    ta_refresher = {
      name = "QuotaMonitor-TARefresher"
      description = "SO0005 quota-monitor-for-aws - TA Refresher Function"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 60
      memory_size = 128
      layers = ["utils_ta"]
      s3_bucket = "solutions-${data.aws_region.current.name}"
      s3_key = "quota-monitor-for-aws/v6.3.0/assete062344a6a45f8d5d2900b99e0126935391d50d4577da563c08475673a012f4c.zip"
      environment_variables = {
        LOG_LEVEL = "info"
        AWS_SERVICES = "AutoScaling,CloudFormation,DynamoDB,EBS,EC2,ELB,IAM,Kinesis,RDS,Route53,SES,VPC"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      dead_letter_config = {
        target_arn = "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:QuotaMonitor-TARefresher-DLQ"
      }
      logging_config = {
        log_format = "Text"
        retention_in_days = 7
      }
    }
  }

  # IAM Roles
  create_role = true
  iam_roles = {
    ta_ok_events = {
      name = "TAOkRuleEventsRole"
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
      policies = {
        events = jsonencode({
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
    }
    ta_warn_events = {
      name = "TAWarnRuleEventsRole"
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
      policies = {
        events = jsonencode({
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
    }
    ta_error_events = {
      name = "TAErrorRuleEventsRole"
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
      policies = {
        events = jsonencode({
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
    }
    ta_refresher = {
      name = "TARefresherRole"
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
      policies = {
        ta_refresh = jsonencode({
          Version = "2012-10-17"
          Statement = [
            {
              Effect = "Allow"
              Action = "support:RefreshTrustedAdvisorCheck"
              Resource = "*"
            }
          ]
        })
      }
    }
  }

  # App Registry
  app_registry = {
    enabled = true
    name = "QM-${data.aws_region.current.name}-${data.aws_caller_identity.current.account_id}"
    description = "Service Catalog application for quota-monitor-for-aws"
    tags = {
      ApplicationType = "AWS-Solutions"
      SolutionID = "SO0005"
      SolutionName = "quota-monitor-for-aws"
      SolutionVersion = "v6.3.0"
    }
  }

  # App Registry Attribute Group
  app_registry_attribute_group = {
    name = "quota-monitor-attributes"
    description = "Quota Monitor Attributes"
    attributes = {
      version = "v6.3.0"
      environment = "production"
    }
    tags = {
      ApplicationType = "AWS-Solutions"
      SolutionID = "SO0005"
      SolutionName = "quota-monitor-for-aws"
      SolutionVersion = "v6.3.0"
    }
  }

  # Additional Tags
  additional_tags = {
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
  default = "arn:aws:events:us-east-1:123456789012:event-bus/QuotaMonitorBus"
}

variable "ta_refresh_rate" {
  type = string
  default = "rate(12 hours)"
  description = "The rate at which to refresh Trusted Advisor checks"
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

output "spoke_sns_event_bus" {
  description = "SNS Event Bus Arn in spoke account"
  value = module.spoke.eventbridge_bus_arns["sns_spoke"]
}