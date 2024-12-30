resource "aws_cloudwatch_log_group" "lambda" {
  for_each = { for k, v in var.lambda_functions : k => v if var.create_lambda && var.create && v.logging_config.log_group != null }

  name              = format("/aws/lambda/%s", substr(format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key)), 0, 63))
  retention_in_days = var.cloudwatch_log_group.retention_in_days
  log_group_class   = var.cloudwatch_log_group.log_group_class
  kms_key_id        = var.cloudwatch_log_group.kms_key_id

  tags = merge(
    var.additional_tags,
    var.cloudwatch_log_group.tags
  )
}