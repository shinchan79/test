module "sns_spoke" {
  source = "./modules/infrastructure"

  # Common
  create        = true
  master_prefix = "QuotaMonitor"

  # Event Bus
  create_event = true
  event_buses = {
    sns_spoke = {
      name = "QuotaMonitorSnsSpokeBus"
    }
  }

  event_bus_policies = {
    sns_spoke = {
      bus_name = module.sns_spoke.event_bus_names["sns_spoke"]
      statements = [
        {
          sid    = "allowed_accounts"
          effect = "Allow"
          principals = {
            AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
          }
          actions   = ["events:PutEvents"]
          resources = [module.sns_spoke.event_bus_arns["sns_spoke"]]
        }
      ]
    }
  }

  # Lambda Layer
  create_lambda_layer = true
  lambda_layers = {
    utils = {
      name                = "QM-UtilsLayer-quota-monitor-sns-spoke"
      description         = "Utilities layer for Quota Monitor"
      compatible_runtimes = ["nodejs18.x"]
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key    = "quota-monitor-for-aws/v6.3.0/assete8b91b89616aa81e100a9f9ce53981ad5df4ba7439cebca83d5dc68349ed3703.zip"
      }
    }
  }

  # SSM Parameters
  create_ssm_parameter = true
  ssm_parameters = {
    notification_muting = {
      name        = "/QuotaMonitor/spoke/NotificationConfiguration"
      type        = "StringList"
      value       = "NOP"
      description = "Muting configuration for services, limits e.g. ec2:L-1216C47A,ec2:Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances,dynamodb,logs:*,geo:L-05EFD12D"
    }
  }

  # SNS Topic
  create_sns = true
  sns_topics = {
    quota_monitor = {
      name              = "QuotaMonitorSnsTopic"
      kms_master_key_id = "alias/aws/sns"
    }
  }

  # Lambda Functions
  create_lambda = true
  lambda_functions = {
    sns_publisher = {
      name        = "QM-SNSPublisher-Lambda"
      description = "SO0005 quota-monitor-for-aws - QM-SNSPublisher-Lambda"
      handler     = "index.handler"
      runtime     = "nodejs18.x"
      timeout     = 60
      memory_size = 128
      environment_variables = {
        QM_NOTIFICATION_MUTING_CONFIG_PARAMETER = module.sns_spoke.ssm_parameter_names["notification_muting"]
        SEND_METRIC                             = "No"
        TOPIC_ARN                               = module.sns_spoke.sns_topic_arns["quota_monitor"]
        LOG_LEVEL                               = "info"
        CUSTOM_SDK_USER_AGENT                   = "AwsSolution/SO0005/v6.3.0"
        VERSION                                 = "v6.3.0"
        SOLUTION_ID                             = "SO0005"
      }
      dead_letter_config = {
        target_arn = module.sns_spoke.sqs_queue_arns["sns_publisher_dlq"]
      }
      layers = [module.sns_spoke.lambda_layer_arns["utils"]]
      filename = {
        s3_bucket = "solutions-${data.aws_region.current.name}"
        s3_key    = "quota-monitor-for-aws/v6.3.0/assete7a324e67e467d0c22e13b0693ca4efdceb0d53025c7fb45fe524870a5c18046.zip"
      }
      event_invoke_config = {
        maximum_event_age_in_seconds = 14400
        qualifier                    = "$LATEST"
      }
      role_policies = {
        sns_publish = {
          actions   = ["sns:Publish"]
          resources = [module.sns_spoke.sns_topic_arns["quota_monitor"]]
        }
        kms = {
          actions   = ["kms:GenerateDataKey"]
          resources = ["arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alias/aws/sns"]
        }
        ssm = {
          actions   = ["ssm:GetParameter"]
          resources = [module.sns_spoke.ssm_parameter_arns["notification_muting"]]
        }
        sqs = {
          actions   = ["sqs:SendMessage"]
          resources = [module.sns_spoke.sqs_queue_arns["sns_publisher_dlq"]]
        }
      }
    }
  }

  # Event Rules
  event_rules = {
    sns_publisher = {
      name           = "QM-SNSPublisher-EventsRule"
      description    = "SO0005 quota-monitor-for-aws - QM-SNSPublisher-EventsRule"
      event_bus_name = module.sns_spoke.event_bus_names["sns_spoke"]
      event_pattern = jsonencode({
        source      = ["aws.trustedadvisor", "aws-solutions.quota-monitor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification", "Service Quotas Utilization Notification"]
        detail = {
          status = ["WARN", "ERROR"]
        }
      })
      targets = [
        {
          arn       = module.sns_spoke.lambda_function_arns["sns_publisher"]
          target_id = "SNSPublisherTarget"
        }
      ]
    }
  }

  # SQS Queues
  create_sqs = true
  sqs_queues = {
    sns_publisher_dlq = {
      name              = "QM-SNSPublisher-DLQ"
      kms_master_key_id = "alias/aws/sqs"
    }
  }

  sqs_queue_policies = {
    sns_publisher_dlq = {
      queue_key = "sns_publisher_dlq"
      statements = [
        {
          sid    = "DenyNonSecureTransport"
          effect = "Deny"
          principals = {
            AWS = "*"
          }
          actions   = ["sqs:*"]
          resources = [module.sns_spoke.sqs_queue_arns["sns_publisher_dlq"]]
          conditions = {
            Bool = {
              "aws:SecureTransport" = "false"
            }
          }
        }
      ]
    }
  }

  # AppRegistry
  create_app_registry = true
  app_registry = {
    name        = format("%s-%s", data.aws_region.current.name, data.aws_caller_identity.current.account_id)
    description = "Service Catalog application to track and manage all your resources for the solution quota-monitor-for-aws"
  }

  app_registry_attribute_group = {
    name        = format("%s-%s", data.aws_region.current.name, data.aws_caller_identity.current.account_id)
    description = "Attribute group for application information"
    attributes = {
      solutionID      = "SO0005-SPOKE-SNS"
      solutionName    = "quota-monitor-for-aws"
      version         = "v6.3.0"
      applicationType = "AWS-Solutions"
    }
  }

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID      = "SO0005-SPOKE-SNS"
    SolutionName    = "quota-monitor-for-aws"
    SolutionVersion = "v6.3.0"
  }
}

# Data sources
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
