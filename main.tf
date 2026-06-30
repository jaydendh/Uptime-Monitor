resource "azurerm_resource_group" "rg" {
  name     = "rg-uptime-monitor-${var.yourname}"
  location = var.location
}

resource "azurerm_storage_account" "main" {
  name                     = "stuptime${var.yourname}"
  location                 = azurerm_resource_group.rg.location
  resource_group_name      = azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_table" "main" {
  name                 = "uptimechecks"
  storage_account_name = azurerm_storage_account.main.name
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-uptime-${var.yourname}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "main" {
  name                = "appi-uptime-${var.yourname}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
}

resource "azurerm_service_plan" "main" {
  name                = "asp-uptime-${var.yourname}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_linux_function_app" "main" {
  name                       = "func-uptime-${var.yourname}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key
  service_plan_id            = azurerm_service_plan.main.id

  site_config {
    application_stack {
      python_version = "3.9"
    }
  }

  app_settings = {
    "TargetUrl"                      = var.target_url
    "APPINSIGHTS_INSTRUMENTATIONKEY" = azurerm_application_insights.main.instrumentation_key
    "APPINSIGHTS_CONNECTION_STRING"  = azurerm_application_insights.main.connection_string
    "AzureWebJobsStorage"            = azurerm_storage_account.main.primary_connection_string
    "FUNCTIONS_WORKER_RUNTIME"       = "python"
    "WEBSITE_RUN_FROM_PACKAGE"       = "1"
  }
}

resource "azurerm_monitor_action_group" "downtime_alerts" {
  name                = "ag-uptime-${var.yourname}"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "uptime"

  email_receiver {
    name                    = "owner-email"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }

  sms_receiver {
    name         = "owner-sms"
    country_code = "1"
    phone_number = replace(replace(var.alert_phone, "+1", ""), "-", "")
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "site_down" {
  name                = "alert-site-down-${var.yourname}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  description         = "Alert when the monitored site is down"
  severity            = "1"
  enabled             = true

  scopes                  = [azurerm_log_analytics_workspace.main.id]
  evaluation_frequency    = "PT5M"
  window_duration         = "PT5M"
  auto_mitigation_enabled = true

  criteria {
    query = <<QUERY
            AppTraces
            | where SeverityLevel == 3
            | where Message contains "SITE DOWN"
            | summarize count() by bin (TimeGenerated, 5m)
            | where count_ > 0
        QUERY

    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
  }

  action {
    action_groups = [azurerm_monitor_action_group.downtime_alerts.id]
  }

}