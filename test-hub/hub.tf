module "hub" {
  source = "../modules/infrastructure"

  # Common
  create        = true
  master_prefix = "QuotaMonitor"
  additional_tags = {
    ApplicationType = "AWS-Solutions"
    SolutionID      = "SO0005"
    SolutionName    = "quota-monitor-for-aws"
    SolutionVersion = "v6.3.0"
  }

  # EventBus
  create_event = true
  event_buses = {
    main = {
      name = "QuotaMonitorBus"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect = "Allow"
            Principal = {
              AWS = "*"
            }
            Action   = "events:PutEvents"
            Resource = "arn:${data.aws_partition.current.partition}:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:event-bus/QuotaMonitorBus"
          }
        ]
      })
    }
  }

  # SSM Parameters
  create_ssm_parameter = true
  ssm_parameters = {
    slack_hook = {
      name        = "/QuotaMonitor/SlackHook"
      type        = "String"
      value       = "NOP"
      description = "Slack Hook URL to send Quota Monitor events"
      tier        = "Standard"
    }
    ous = {
      name        = "/QuotaMonitor/OUs"
      type        = "StringList"
      value       = "NOP"
      description = "List of target Organizational Units"
      tier        = "Standard"
    }
    accounts = {
      name        = "/QuotaMonitor/Accounts"
      type        = "StringList"
      value       = "NOP"
      description = "List of target Accounts"
      tier        = "Standard"
    }
    notification_muting = {
      name        = "/QuotaMonitor/NotificationConfiguration"
      type        = "StringList"
      value       = "NOP"
      description = "Muting configuration for services, limits"
      tier        = "Standard"
    }
    regions_list = {
      name        = "/QuotaMonitor/RegionsToDeploy"
      type        = "StringList"
      value       = var.regions_list
      description = "List of regions to deploy spoke resources"
      tier        = "Standard"
    }
  }

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

  # Lambda Functions
  create_lambda = true
  lambda_functions = {
    helper = {
      name        = "QM-Helper-Function"
      description = "SO0005 quota-monitor-for-aws - QM-Helper-Function"
      handler     = "QM-Helper-Function.handler"
      runtime     = "python3.9"
      timeout     = 5
      memory_size = 128
      layers      = ["utils"]
      environment_variables = {
        METRICS_ENDPOINT      = "https://metrics.awssolutionsbuilder.com/generic"
        SEND_METRIC           = "Yes"
        QM_STACK_ID           = "quota-monitor-hub"
        QM_SLACK_NOTIFICATION = "No"
        QM_EMAIL_NOTIFICATION = "No"
        SAGEMAKER_MONITORING  = "Yes"
        CONNECT_MONITORING    = "Yes"
        LOG_LEVEL             = "info"
        CUSTOM_SDK_USER_AGENT = "AwsSolution/SO0005/v6.3.0"
        VERSION               = "v6.3.0"
        SOLUTION_ID           = "SO0005"
      }
      logging_config = {
        log_format        = "Text"
        retention_in_days = 7
      }
      source_dir = "${path.module}/../lambda_sources/helper"
      role_arn   = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/QM-Helper-Function-Role"
    }
    deployment_manager = {
      name        = "QM-Deployment-Manager-Function"
      description = "SO0005 quota-monitor-for-aws - QM-Deployment-Manager-Function"
      handler     = "QM-Deployment-Manager-Function.handler"
      runtime     = "python3.9"
      timeout     = 60
      memory_size = 512
      layers      = ["utils"]
      environment_variables = {
        EVENT_BUS_NAME               = "QuotaMonitorBus"
        EVENT_BUS_ARN                = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:event-bus/QuotaMonitorBus"
        QM_OU_PARAMETER              = "/QuotaMonitor/OUs"
        QM_ACCOUNT_PARAMETER         = "/QuotaMonitor/Accounts"
        DEPLOYMENT_MODEL             = var.deployment_model
        REGIONS_LIST                 = var.regions_list
        QM_REGIONS_LIST_PARAMETER    = "/QuotaMonitor/RegionsToDeploy"
        SNS_SPOKE_REGION             = var.sns_spoke_region
        REGIONS_CONCURRENCY_TYPE     = var.region_concurrency
        MAX_CONCURRENT_PERCENTAGE    = var.max_concurrent_percentage
        FAILURE_TOLERANCE_PERCENTAGE = var.failure_tolerance_percentage
        SQ_NOTIFICATION_THRESHOLD    = "80"
        SQ_MONITORING_FREQUENCY      = "rate(12 hours)"
        SQ_REPORT_OK_NOTIFICATIONS   = "No"
        LOG_LEVEL                    = "info"
        CUSTOM_SDK_USER_AGENT        = "AwsSolution/SO0005/v6.3.0"
        VERSION                      = "v6.3.0"
        SOLUTION_ID                  = "SO0005"
      }
      logging_config = {
        log_format        = "Text"
        retention_in_days = 7
      }
      source_dir = "${path.module}/../lambda_sources/deployment-manager"
      role_arn   = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/QM-Deployment-Manager-Function-Role"
    }
  }

  # Event Rules
  event_rules = {
    deployment_manager = {
      name        = "QM-Deployment-Manager-EventsRule"
      description = "EventRule for QM-Deployment-Manager-Function"
      event_pattern = jsonencode({
        source = ["aws.organizations"]
        detail-type = [
          "AWS API Call via CloudTrail",
          "AWS Service Event via CloudTrail"
        ]
        detail = {
          eventSource = ["organizations.amazonaws.com"]
          eventName = [
            "AcceptHandshake",
            "CreateAccount",
            "CreateGovCloudAccount",
            "InviteAccountToOrganization"
          ]
        }
      })
      targets = [{
        arn = "arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:QM-Deployment-Manager-Function"
        id  = "QM-Deployment-Manager-Function"
      }]
    }
  }

  # SQS Queue
  create_sqs = true
  sqs_queue = {
    deployment_manager_dlq = {
      name              = "QM-Deployment-Manager-DLQ"
      kms_master_key_id = "alias/aws/sqs"
    }
  }

  # SNS Topic
  create_sns = true
  sns_topic = {
    main = {
      name              = "QM-SNS-Topic"
      kms_master_key_id = "alias/aws/sns"
    }
  }

  # DynamoDB Tables
  create_dynamodb = true
  dynamodb_tables = {
    main = {
      name         = "QM-DynamoDB-Table"
      billing_mode = "PAY_PER_REQUEST"
      hash_key     = "id"
      range_key    = "type"
      attributes = [
        {
          name = "id"
          type = "S"
        },
        {
          name = "type"
          type = "S"
        }
      ]
      global_secondary_indexes = [
        {
          name            = "TypeIndex"
          hash_key        = "type"
          projection_type = "ALL"
        }
      ]
      server_side_encryption = {
        enabled     = true
        kms_key_arn = "arn:${data.aws_partition.current.partition}:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alias/aws/dynamodb"
      }
    }
  }

  # AppRegistry
  app_registry = {
    enabled     = true
    name        = format("QM_Hub_Org_%s_%s", data.aws_region.current.name, data.aws_caller_identity.current.account_id)
    description = "Service Catalog application to track and manage all your resources for the solution quota-monitor-for-aws"
  }

  app_registry_attribute_group = {
    name        = format("QM_Hub_Org_%s_%s", data.aws_region.current.name, data.aws_caller_identity.current.account_id)
    description = "Attribute group for application information"
    attributes = {
      solutionID      = "SO0005"
      solutionName    = "quota-monitor-for-aws"
      version         = "v6.3.0"
      applicationType = "AWS-Solutions"
    }
  }
}

# Data sources
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Variables
variable "regions_list" {
  type    = string
  default = "ALL"
}

variable "sns_spoke_region" {
  type    = string
  default = ""
}

variable "deployment_model" {
  type    = string
  default = "Organizations"
}

variable "region_concurrency" {
  type    = string
  default = "PARALLEL"
}

variable "max_concurrent_percentage" {
  type    = number
  default = 100
}

variable "failure_tolerance_percentage" {
  type    = number
  default = 0
}