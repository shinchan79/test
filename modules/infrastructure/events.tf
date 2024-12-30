resource "aws_cloudwatch_event_bus" "event_bus" {
  for_each           = var.create_event && var.create ? var.event_buses : {}
  name               = substr(format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key)), 0, 63)
  kms_key_identifier = each.value.kms_key_identifier
  tags               = merge(var.additional_tags, each.value.tags)
}

resource "aws_cloudwatch_event_bus_policy" "bus_policy" {
  for_each       = var.create_event && var.create ? var.event_buses : {}
  policy         = each.value.policy
  event_bus_name = aws_cloudwatch_event_bus.event_bus[each.key].name
}

resource "aws_cloudwatch_event_rule" "event_rule" {
  for_each            = var.create_event && var.create ? var.event_rules : {}
  name                = substr(format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key)), 0, 63)
  event_bus_name      = try(aws_cloudwatch_event_bus.event_bus[each.value.event_bus_key].name, each.value.event_bus)
  description         = each.value.description
  schedule_expression = each.value.schedule_expression
  event_pattern       = each.value.event_pattern
  state               = each.value.state
  force_destroy       = each.value.force_destroy
  tags                = merge(var.additional_tags, each.value.tags)

  depends_on = [
    aws_cloudwatch_event_bus.event_bus
  ]
}

resource "random_uuid" "event_target" {
  for_each = var.create_event && var.create ? var.event_targets : {}
}

resource "aws_cloudwatch_event_target" "event_target" {
  for_each       = var.create_event && var.create ? var.event_targets : {}
  target_id      = random_uuid.event_target[each.key].result
  rule           = try(aws_cloudwatch_event_rule.event_rule[each.value.rule_key].name, each.value.rule)
  event_bus_name = try(aws_cloudwatch_event_bus.event_bus[each.value.event_bus_key].name, each.value.event_bus)
  arn            = try(aws_sqs_queue.queue[each.value.target_sqs_key].arn, each.value.target_arn)
  role_arn       = each.value.role_arn

  dynamic "input_transformer" {
    for_each = each.value.input_transformer != null ? [each.value.input_transformer] : []
    content {
      input_paths    = input_transformer.value.input_paths
      input_template = input_transformer.value.input_template
    }
  }
  depends_on = [
    aws_cloudwatch_event_rule.event_rule
  ]
}

resource "aws_scheduler_schedule" "schedule" {
  for_each = var.create_event && var.create ? var.event_schedules : {}
  name     = substr(format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key)), 0, 63)

  flexible_time_window {
    mode = each.value.flexible_time_window
  }

  schedule_expression = each.value.schedule_expression
  kms_key_arn         = each.value.kms_key_arn
  group_name          = try(aws_scheduler_schedule_group.schedule[each.value.group_name].name, each.value.group_name)

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:sqs:sendMessage"
    role_arn = each.value.role_arn

    input = each.value.input
  }
}

resource "aws_scheduler_schedule_group" "schedule" {
  for_each = var.create_event && var.create ? var.event_schedule_groups : {}
  name     = substr(format("%s-%s", var.master_prefix, coalesce(each.value.name, each.key)), 0, 63)
}