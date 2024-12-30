resource "aws_lambda_layer_version" "this" {
  for_each = local.lambda_layer

  layer_name          = each.value.name
  description         = each.value.description
  compatible_runtimes = each.value.compatible_runtimes

  s3_bucket = each.value.s3_bucket
  s3_key    = each.value.s3_key
}
