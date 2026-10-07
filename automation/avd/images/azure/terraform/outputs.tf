output "template_ids" {
  value = [for template in var.templates : azapi_resource.image_template[template.key].id]
}

output "template_names" {
  value = [for template in var.templates : azapi_resource.image_template[template.key].name]
}
