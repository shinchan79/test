data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "sqs_policy" {
  for_each = { for k, v in var.sqs_queue : k => v if v.policy == null && var.create_sqs && var.create }

  statement {
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions = [
      "sqs:SendMessage"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${format("%s-%s", var.master_prefix, coalesce(var.sqs_queue[each.key].name, each.key))}"
    ]
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [
        "arn:${data.aws_partition.current.partition}:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:rule/*"
      ]
    }
  }
}