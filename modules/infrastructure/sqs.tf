resource "aws_sqs_queue" "queue" {
  for_each = var.create_sqs && var.create ? var.sqs_queue : {}

  name                      = format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key))
  delay_seconds             = each.value.delay_seconds
  max_message_size          = each.value.max_message_size
  message_retention_seconds = each.value.message_retention_seconds
  receive_wait_time_seconds = each.value.receive_wait_time_seconds
  fifo_queue                = each.value.fifo_queue
  policy                    = each.value.policy
  kms_master_key_id         = each.value.kms_master_key_id
  tags                      = merge(var.additional_tags, each.value.tags)
}

resource "aws_sqs_queue_policy" "policy" {
  for_each = { for k, v in var.sqs_queue : k => v if v.policy == null && var.create_sqs && var.create }

  queue_url = aws_sqs_queue.queue[each.key].id
  policy    = data.aws_iam_policy_document.sqs_policy[each.key].json

  depends_on = [aws_sqs_queue.queue]
}