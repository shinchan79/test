resource "aws_iam_role" "role" {
  for_each = var.create_role && var.create ? var.iam_roles : {}

  name                  = substr(format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key)), 0, 63)
  description           = each.value.description
  path                  = each.value.path
  force_detach_policies = each.value.force_detach_policies
  permissions_boundary  = each.value.permissions_boundary
  assume_role_policy    = each.value.assume_role_policy

  tags = merge(
    { Name = substr(format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key)), 0, 63) },
    var.additional_tags,
    each.value.tags
  )
}

resource "aws_iam_role_policy" "policies" {
  for_each = { for pair in local.iam_policies : format("%s-%s", pair[0], pair[1]) => pair }

  name = substr(format("%s-%s-pl", coalesce(var.iam_roles[each.value[0]].name, each.value[0]), each.value[1]), 0, 63)

  policy = var.iam_roles[each.value[0]].policies[each.value[1]] # The actual policy document or ARN
  role   = aws_iam_role.role[each.value[0]].name
}


resource "aws_iam_role_policy_attachment" "additional_policies" {
  for_each   = { for pair in local.iam_additional_policies : format("%s-%s", pair[0], pair[1]) => pair }
  policy_arn = each.value[1]
  role       = aws_iam_role.role[each.value[0]].name
}