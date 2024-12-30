resource "aws_dynamodb_table" "table" {
  for_each                    = { for k, v in var.dynamodb_tables : k => v if var.create_dynamodb && var.create }
  name                        = format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key))
  billing_mode                = each.value.billing_mode
  hash_key                    = each.value.hash_key
  range_key                   = each.value.range_key
  stream_enabled              = each.value.stream_enabled
  stream_view_type            = each.value.stream_view_type
  table_class                 = each.value.table_class
  deletion_protection_enabled = each.value.deletion_protection_enabled

  # Only set read and write capacity when billing mode is PROVISIONED
  read_capacity  = each.value.billing_mode == "PROVISIONED" ? each.value.read_capacity : null
  write_capacity = each.value.billing_mode == "PROVISIONED" ? each.value.write_capacity : null

  dynamic "server_side_encryption" {
    for_each = each.value.server_side_encryption != null ? [each.value.server_side_encryption] : []
    content {
      enabled     = server_side_encryption.value.enabled
      kms_key_arn = server_side_encryption.value.kms_key_arn
    }
  }

  dynamic "attribute" {
    for_each = { for v in each.value.attributes : v.name => v }
    content {
      name = attribute.value.name
      type = attribute.value.type
    }
  }

  dynamic "local_secondary_index" {
    for_each = { for v in each.value.local_secondary_index : v.name => v }

    content {
      name               = local_secondary_index.value.name
      range_key          = local_secondary_index.value.range_key
      projection_type    = local_secondary_index.value.projection_type
      non_key_attributes = local_secondary_index.value.non_key_attributes
    }
  }

  lifecycle {
    ignore_changes = [
      read_capacity,
      write_capacity
    ]
  }

  tags = merge(var.additional_tags, each.value.tags)
}