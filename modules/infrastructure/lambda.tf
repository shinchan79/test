data "archive_file" "lambda" {
  for_each = var.create_lambda && var.create ? var.lambda_functions : {}

  type        = "zip"
  source_file = format("${path.module}/%s/%s.py", 
    each.value.source_dir,
    each.value.handler != null ? split(".", each.value.handler)[0] : each.value.name
  )
  output_path = "${path.module}/archive_file/${coalesce(each.value.source_file, each.value.name, each.key)}.zip"
}

resource "aws_lambda_function" "lambda" {
  for_each = var.create_lambda && var.create ? var.lambda_functions : {}

  filename         = data.archive_file.lambda[each.key].output_path
  function_name    = substr(format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key)), 0, 63)
  role             = try(aws_iam_role.role[each.value.role_key].arn, each.value.role_arn)
  handler          = format("%s.%s", coalesce(each.value.source_file, each.value.name, each.key), each.value.handler)
  source_code_hash = data.archive_file.lambda[each.key].output_base64sha256
  runtime          = each.value.runtime
  timeout          = each.value.timeout
  memory_size      = each.value.memory_size
  architectures    = each.value.architectures
  kms_key_arn      = each.value.kms_key_arn

  environment {
    variables = each.value.environment_variables
  }

  dynamic "vpc_config" {
    for_each = each.value.security_group_ids != null && each.value.subnet_ids != null ? [1] : []
    content {
      security_group_ids = each.value.security_group_ids
      subnet_ids         = each.value.subnet_ids
    }
  }

  dynamic "logging_config" {
    for_each = each.value.logging_config != null ? [1] : []
    content {
      application_log_level = each.value.logging_config.application_log_level
      log_format            = each.value.logging_config.log_format
      log_group             = try(aws_cloudwatch_log_group.lambda[each.key].name, each.value.logging_config.log_group)
      system_log_level      = each.value.logging_config.system_log_level
    }
  }

  tags = merge(
    var.additional_tags,
    each.value.tags
  )

  depends_on = [
    aws_cloudwatch_log_group.lambda
  ]
}