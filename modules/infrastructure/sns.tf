resource "aws_sns_topic" "topic" {
  for_each = var.create_sns && var.create ? var.sns_topic : {}

  name              = format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key))
  kms_master_key_id = each.value.kms_master_key_id
  tags              = merge(var.additional_tags, each.value.tags)
}