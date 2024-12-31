resource "aws_ssm_parameter" "parameters" {
  for_each = var.create && var.create_ssm_parameter ? var.ssm_parameters : {}

  name        = format("%s%s", var.master_prefix, each.value.name)
  description = each.value.description
  type        = each.value.type
  value       = each.value.value

  allowed_pattern = each.value.allowed_pattern
  data_type       = each.value.data_type
  key_id          = each.value.key_id
  tier            = each.value.tier
  tags            = merge(var.additional_tags, each.value.tags)
}