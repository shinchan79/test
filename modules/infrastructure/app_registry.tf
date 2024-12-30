resource "aws_servicecatalogappregistry_application" "quota_monitor_app" {
  count = var.app_registry.enabled ? 1 : 0

  name        = var.app_registry.name
  description = var.app_registry.description
}

resource "aws_servicecatalogappregistry_attribute_group" "quota_monitor_attribute_group" {
  count = var.app_registry.enabled ? 1 : 0

  name        = var.app_registry_attribute_group.name
  description = var.app_registry_attribute_group.description
  
  # attributes must be a JSON string
  attributes = jsonencode(var.app_registry_attribute_group.attributes)
  tags = var.app_registry_attribute_group.tags
}

resource "aws_servicecatalogappregistry_attribute_group_association" "quota_monitor_association" {
  count = var.app_registry.enabled ? 1 : 0

  application_id      = aws_servicecatalogappregistry_application.quota_monitor_app[0].id
  attribute_group_id  = aws_servicecatalogappregistry_attribute_group.quota_monitor_attribute_group[0].id
}