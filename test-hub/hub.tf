module "hub" {
  source = "../modules/infrastructure"
  
  # Common
  create = true
  master_prefix = "QuotaMonitor"
  
  # EventBus
  create_event = true
  event_buses = {
    main = {
      name = "QuotaMonitorBus"
    }
  }

  # KMS
  create_kms = true 
  kms_keys = {
    main = {
      description = "CMK for AWS resources provisioned by Quota Monitor in this account"
      enable_key_rotation = true
      alias = "CMK-KMS-Hub"
      policy = {
        Version = "2012-10-17"
        Statement = [
          {
            Sid = "Enable IAM User Permissions"
            Effect = "Allow"
            Principal = {
              AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
            }
            Action = "kms:*"
            Resource = "*"
          },
          {
            Sid = "Allow EventBridge"
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
      }
    }
  }

  # SSM Parameters
  create_ssm_parameter = true
  ssm_parameters = {
    slack_hook = {
      name = "/QuotaMonitor/SlackHook"
      type = "String"
      value = "NOP"
      description = "Slack Hook URL to send Quota Monitor events"
    }
    ous = {
      name = "/QuotaMonitor/OUs"
      type = "StringList"
      value = "NOP"
      description = "List of target Organizational Units"
    }
    accounts = {
      name = "/QuotaMonitor/Accounts"
      type = "StringList"
      value = "NOP"
      description = "List of target Accounts"
    }
    notification_muting = {
      name = "/QuotaMonitor/NotificationConfiguration"
      type = "StringList"
      value = "NOP"
      description = "Muting configuration for services, limits"
    }
    regions_list = {
      name = "/QuotaMonitor/RegionsToDeploy"
      type = "StringList"
      value = var.regions_list
      description = "List of regions to deploy spoke resources"
    }
  }

  # Lambda Layer
  create_lambda_layer = true
  lambda_layers = {
    utils = {
      name = "QM-UtilsLayer"
      description = "Utilities layer for Quota Monitor"
      compatible_runtimes = ["nodejs18.x"]
      filename = "path/to/layer.zip"
    }
  }

  # Lambda Functions
  create_lambda = true
  lambda_functions = {
    helper = {
      name = "QM-Helper-Function"
      description = "SO0005 quota-monitor-for-aws - QM-Helper-Function"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 5
      memory_size = 128
      environment_variables = {
        METRICS_ENDPOINT = "https://metrics.awssolutionsbuilder.com/generic"
        SEND_METRIC = "Yes"
        LOG_LEVEL = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      layers = [module.hub.lambda_layer_arns["utils"]]
    }

    slack_notifier = {
      name = "QM-SlackNotifier-Lambda"
      description = "SO0005 quota-monitor-for-aws - QM-SlackNotifier-Lambda"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 60
      memory_size = 128
      environment_variables = {
        SLACK_HOOK_PARAMETER = "/QuotaMonitor/SlackHook"
        LOG_LEVEL = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      dead_letter_config = {
        target_arn = module.hub.sqs_queue_arns["slack_notifier_dlq"]
      }
      layers = [module.hub.lambda_layer_arns["utils"]]
    }

    sns_publisher = {
      name = "QM-SNSPublisher-Lambda"
      description = "SO0005 quota-monitor-for-aws - QM-SNSPublisher-Lambda"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 60
      memory_size = 128
      environment_variables = {
        SNS_TOPIC_ARN = module.hub.sns_topic_arns["quota_monitor"]
        LOG_LEVEL = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      dead_letter_config = {
        target_arn = module.hub.sqs_queue_arns["sns_publisher_dlq"]
      }
      layers = [module.hub.lambda_layer_arns["utils"]]
    }

    summarizer = {
      name = "QM-Summarizer-Lambda"
      description = "SO0005 quota-monitor-for-aws - QM-Summarizer-Lambda"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 60
      memory_size = 128
      environment_variables = {
        DYNAMODB_TABLE = module.hub.dynamodb_table_names["quota_monitor"]
        LOG_LEVEL = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      dead_letter_config = {
        target_arn = module.hub.sqs_queue_arns["summarizer_dlq"]
      }
      layers = [module.hub.lambda_layer_arns["utils"]]
    }

    deployment_manager = {
      name = "QM-Deployment-Manager-Lambda"
      description = "SO0005 quota-monitor-for-aws - QM-Deployment-Manager-Lambda"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 60
      memory_size = 512
      environment_variables = {
        EVENT_BUS_NAME = module.hub.event_bus_name
        EVENT_BUS_ARN = module.hub.event_bus_arn
        TA_STACKSET_ID = module.hub.stackset_ids["ta_spoke"]
        SQ_STACKSET_ID = module.hub.stackset_ids["sq_spoke"]
        SNS_STACKSET_ID = module.hub.stackset_ids["sns_spoke"]
        QM_OU_PARAMETER = module.hub.ssm_parameter_names["ous"]
        QM_ACCOUNT_PARAMETER = module.hub.ssm_parameter_names["accounts"]
        DEPLOYMENT_MODEL = var.deployment_model
        REGIONS_LIST = var.regions_list
        QM_REGIONS_LIST_PARAMETER = module.hub.ssm_parameter_names["regions_list"]
        SNS_SPOKE_REGION = var.sns_spoke_region
        REGIONS_CONCURRENCY_TYPE = var.region_concurrency
        MAX_CONCURRENT_PERCENTAGE = var.max_concurrent_percentage
        FAILURE_TOLERANCE_PERCENTAGE = var.failure_tolerance_percentage
        LOG_LEVEL = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      dead_letter_config = {
        target_arn = module.hub.sqs_queue_arns["deployment_manager_dlq"]
      }
      layers = [module.hub.lambda_layer_arns["utils"]]
    }

    reporter = {
      name = "QM-Reporter-Lambda"
      description = "SO0005 quota-monitor-for-aws - QM-Reporter-Lambda"
      handler = "index.handler"
      runtime = "nodejs18.x"
      timeout = 60
      memory_size = 128
      environment_variables = {
        DYNAMODB_TABLE = module.hub.dynamodb_table_names["quota_monitor"]
        SNS_TOPIC_ARN = module.hub.sns_topic_arns["quota_monitor"]
        LOG_LEVEL = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION = "v6.3.0"
        SOLUTION_ID = "SO0005"
      }
      layers = [module.hub.lambda_layer_arns["utils"]]
    }
  }

  # Event Rules
  create_event_rule = true
  event_rules = {
    slack_notifier = {
      name = "QM-SlackNotifier-EventsRule"
      description = "Rule to trigger Slack notifications for quota alerts"
      event_bus_name = module.hub.event_bus_name
      event_pattern = jsonencode({
        source = ["aws.trustedadvisor", "aws-solutions.quota-monitor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification", "Service Quotas Utilization Notification"]
      })
      targets = [
        {
          arn = module.hub.lambda_function_arns["slack_notifier"]
          target_id = "SlackNotifierTarget"
        }
      ]
    }

    sns_publisher = {
      name = "QM-SNSPublisher-EventsRule"
      description = "Rule to trigger SNS notifications for quota alerts"
      event_bus_name = module.hub.event_bus_name
      event_pattern = jsonencode({
        source = ["aws.trustedadvisor", "aws-solutions.quota-monitor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification", "Service Quotas Utilization Notification"]
        detail = {
          status = ["WARN", "ERROR"]
        }
      })
      targets = [
        {
          arn = module.hub.lambda_function_arns["sns_publisher"]
          target_id = "SNSPublisherTarget"
        }
      ]
    }

    summarizer = {
      name = "QM-Summarizer-EventsRule"
      description = "Rule to trigger summarization of quota alerts"
      event_bus_name = module.hub.event_bus_name
      event_pattern = jsonencode({
        source = ["aws.trustedadvisor", "aws-solutions.quota-monitor"]
        detail-type = ["Trusted Advisor Check Item Refresh Notification", "Service Quotas Utilization Notification"]
      })
      targets = [
        {
          arn = module.hub.sqs_queue_arns["summarizer"]
          target_id = "SummarizerQueueTarget"
        }
      ]
    }

    reporter = {
      name = "QM-Reporter-EventsRule"
      description = "Rule to trigger reporting of quota alerts"
      event_bus_name = module.hub.event_bus_name
      schedule_expression = "rate(1 day)"
      targets = [
        {
          arn = module.hub.lambda_function_arns["reporter"]
          target_id = "ReporterTarget"
        }
      ]
    }
  }

  # SQS Queues
  create_sqs = true
  sqs_queues = {
    slack_notifier_dlq = {
      name = "QM-SlackNotifier-DLQ"
      kms_master_key_id = module.hub.kms_key_arn
    }
    sns_publisher_dlq = {
      name = "QM-SNSPublisher-DLQ"
      kms_master_key_id = module.hub.kms_key_arn
    }
    summarizer = {
      name = "QM-Summarizer-Queue"
      kms_master_key_id = module.hub.kms_key_arn
      redrive_policy = jsonencode({
        deadLetterTargetArn = module.hub.sqs_queue_arns["summarizer_dlq"]
        maxReceiveCount = 3
      })
    }
    summarizer_dlq = {
      name = "QM-Summarizer-DLQ"
      kms_master_key_id = module.hub.kms_key_arn
    }
    deployment_manager_dlq = {
      name = "QM-DeploymentManager-DLQ"
      kms_master_key_id = module.hub.kms_key_arn
    }
  }

  # SNS Topics
  create_sns = true
  sns_topics = {
    quota_monitor = {
      name = "QuotaMonitorTopic"
      kms_master_key_id = module.hub.kms_key_arn
    }
  }

  # DynamoDB Tables
  create_dynamodb = true
  dynamodb_tables = {
    quota_monitor = {
      name = "QM-Table"
      billing_mode = "PAY_PER_REQUEST"
      hash_key = "id"
      range_key = "type"
      attributes = [
        {
          name = "id"
          type = "S"
        },
        {
          name = "type"
          type = "S"
        },
        {
          name = "accountId"
          type = "S"
        },
        {
          name = "region"
          type = "S"
        }
      ]
      global_secondary_indexes = [
        {
          name = "AccountRegionIndex"
          hash_key = "accountId"
          range_key = "region"
          projection_type = "ALL"
        }
      ]
      server_side_encryption = {
        enabled = true
        kms_key_arn = module.hub.kms_key_arn
      }
    }
  }

  # CloudFormation StackSets
  create_stackset = true
  stacksets = {
    ta_spoke = {
      name = "QM-TA-Spoke-StackSet"
      description = "StackSet for deploying Quota Monitor Trusted Advisor spokes"
      template_url = "https://solutions-${data.aws_region.current.name}.s3.${data.aws_region.current.name}.amazonaws.com/quota-monitor-for-aws/v6.3.0/quota-monitor-ta-spoke.template"
      parameters = {
        EventBusArn = module.hub.event_bus_arn
      }
      capabilities = ["CAPABILITY_IAM"]
      permission_model = "SERVICE_MANAGED"
      call_as = "DELEGATED_ADMIN"
    }
    sq_spoke = {
      name = "QM-SQ-Spoke-StackSet"
      description = "StackSet for deploying Quota Monitor Service Quota spokes"
      template_url = "https://solutions-${data.aws_region.current.name}.s3.${data.aws_region.current.name}.amazonaws.com/quota-monitor-for-aws/v6.3.0/quota-monitor-sq-spoke.template"
      parameters = {
        EventBusArn = module.hub.event_bus_arn
        SpokeSnsRegion = var.sns_spoke_region
      }
      capabilities = ["CAPABILITY_IAM"]
      permission_model = "SERVICE_MANAGED"
      call_as = "DELEGATED_ADMIN"
    }
    sns_spoke = {
      name = "QM-SNS-Spoke-StackSet"
      description = "StackSet for deploying Quota Monitor notification spokes"
      template_url = "https://solutions-${data.aws_region.current.name}.s3.${data.aws_region.current.name}.amazonaws.com/quota-monitor-for-aws/v6.3.0/quota-monitor-sns-spoke.template"
      capabilities = ["CAPABILITY_IAM"]
      permission_model = "SERVICE_MANAGED"
      call_as = "DELEGATED_ADMIN"
    }
  }

  # AppRegistry
  create_app_registry = true
  app_registry = {
    name = format("QM_Hub_Org_%s_%s", data.aws_region.current.name, data.aws_caller_identity.current.account_id)
    description = "Service Catalog application to track and manage all your resources for the solution quota-monitor-for-aws"
  }

  tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID = "SO0005"
    SolutionName = "quota-monitor-for-aws"
    SolutionVersion = "v6.3.0"
  }
}

# Data sources
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Variables
variable "regions_list" {
  type = string
  default = "ALL"
}

variable "sns_spoke_region" {
  type = string
  default = ""
}

variable "deployment_model" {
  type = string
  default = "Organizations"
}

variable "region_concurrency" {
  type = string
  default = "PARALLEL"
}

variable "max_concurrent_percentage" {
  type = number
  default = 100
}

variable "failure_tolerance_percentage" {
  type = number
  default = 0
}
