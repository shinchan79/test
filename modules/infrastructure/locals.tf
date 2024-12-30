locals {
  iam_policies = chunklist(flatten([
    for k, v in var.iam_roles : concat(
      setproduct([k], keys(var.iam_roles[k].policies)),
    ) if var.create_role && var.create && v.policies != null
  ]), 2)

  iam_additional_policies = chunklist(flatten([
    for k, v in var.iam_roles : concat(
      setproduct([k], var.iam_roles[k].additional_policies),
    ) if var.create_role && var.create && v.additional_policies != null
  ]), 2)

  # aws_service_policies = {
  #   sqs_source = {
  #     actions = [
  #       "sqs:ReceiveMessage",
  #       "sqs:DeleteMessage",
  #       "sqs:GetQueueAttributes"
  #     ]
  #   },
  #   sqs_target = {
  #     actions = [
  #       "sqs:SendMessage"
  #     ]
  #   },
  #   sqs_dlq = {
  #     actions = [
  #       "sqs:SendMessage"
  #     ]
  #   },
  #   dynamodb = {
  #     actions = [
  #       "dynamodb:DescribeStream",
  #       "dynamodb:GetRecords",
  #       "dynamodb:GetShardIterator",
  #       "dynamodb:ListStreams"
  #     ]
  #   },
  #   kinesis_source = {
  #     actions = [
  #       "kinesis:DescribeStream",
  #       "kinesis:DescribeStreamSummary",
  #       "kinesis:GetRecords",
  #       "kinesis:GetShardIterator",
  #       "kinesis:ListShards",
  #       "kinesis:ListStreams",
  #       "kinesis:SubscribeToShard"
  #     ]
  #   },
  #   kinesis_target = {
  #     actions = [
  #       "kinesis:PutRecord",
  #       "kinesis:PutRecords"
  #     ]
  #   },
  #   mq = {
  #     actions = [
  #       "mq:DescribeBroker",
  #       "secretsmanager:GetSecretValue",
  #       "ec2:CreateNetworkInterface",
  #       "ec2:DeleteNetworkInterface",
  #       "ec2:DescribeNetworkInterfaces",
  #       "ec2:DescribeSecurityGroups",
  #       "ec2:DescribeSubnets",
  #       "ec2:DescribeVpcs",
  #       "logs:CreateLogGroup",
  #       "logs:CreateLogStream",
  #       "logs:PutLogEvents"
  #     ]
  #   },
  #   msk = {
  #     actions = [
  #       "kafka:DescribeClusterV2",
  #       "kafka:GetBootstrapBrokers",
  #       "ec2:CreateNetworkInterface",
  #       "ec2:DeleteNetworkInterface",
  #       "ec2:DescribeNetworkInterfaces",
  #       "ec2:DescribeSecurityGroups",
  #       "ec2:DescribeSubnets",
  #       "ec2:DescribeVpcs",
  #       "logs:CreateLogGroup",
  #       "logs:CreateLogStream",
  #       "logs:PutLogEvents"
  #     ]
  #   },
  #   lambda = {
  #     actions = [
  #       "lambda:InvokeFunction"
  #     ]
  #   },
  #   step_functions = {
  #     actions = [
  #       "states:StartExecution"
  #     ]
  #   },
  #   api_gateway = {
  #     actions = [
  #       "execute-api:Invoke"
  #     ]
  #   },
  #   api_destination = {
  #     actions = [
  #       "events:InvokeApiDestination"
  #     ]
  #   },
  #   batch = {
  #     actions = [
  #       "batch:SubmitJob"
  #     ]
  #   },
  #   logs = {
  #     actions = [
  #       "logs:DescribeLogGroups",
  #       "logs:DescribeLogStreams",
  #       "logs:CreateLogStream",
  #       "logs:PutLogEvents"
  #     ]
  #   },
  #   ecs = {
  #     actions = [
  #       "ecs:RunTask"
  #     ]
  #   },
  #   ecs_iam_passrole = {
  #     actions = [
  #       "iam:PassRole"
  #     ]
  #   },
  #   eventbridge = {
  #     actions = [
  #       "events:PutEvents"
  #     ]
  #   },
  #   firehose = {
  #     actions = [
  #       "firehose:PutRecord"
  #     ]
  #   },
  #   inspector = {
  #     actions = [
  #       "inspector:CreateAssessmentTemplate"
  #     ]
  #   },
  #   redshift = {
  #     actions = [
  #       "redshift-data:ExecuteStatement"
  #     ]
  #   },
  #   sagemaker = {
  #     actions = [
  #       "sagemaker:CreatePipeline"
  #     ]
  #   },
  #   sns = {
  #     actions = [
  #       "sns:Publish"
  #     ]
  #   }
  # }
  lambda_layer = {
    for k, v in var.lambda_layers : k => {
      name                = try(v.name, "${var.master_prefix}-${k}-layer")
      description         = try(v.description, null)
      compatible_runtimes = try(v.compatible_runtimes, null)
      filename            = try(v.filename, null)
      s3_bucket          = try(v.filename.s3_bucket, null)
      s3_key             = try(v.filename.s3_key, null)
    } if var.create && var.create_lambda_layer
  }
}