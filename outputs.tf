output "function_app_name" {
  value = azurerm_linux_function_app.main.name
}

output "application_insights_name" {
  value = azurerm_application_insights.main.name
}

output "storage_table_name" {
  value = azurerm_storage_table.main.name
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

