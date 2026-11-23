# ==================================================
# Table names and schemas (defined once, reused for the tables AND the DCR
# stream declarations, exactly like main.bicep).
# ==================================================

locals {
  device_table = "PowerStacksDeviceInventory_CL"
  app_table    = "PowerStacksAppInventory_CL"
  driver_table = "PowerStacksDriverInventory_CL"

  device_columns = concat(
    [
      { name = "TimeGenerated", type = "datetime" },
      { name = "ComputerName_s", type = "string" },
      { name = "ManagedDeviceID_g", type = "string" },
      { name = "Microsoft365_b", type = "boolean" },
      { name = "Warranty_b", type = "boolean" },
    ],
    [for i in range(1, 11) : { name = "DeviceDetails${i}_s", type = "string" }],
  )

  app_columns = concat(
    [
      { name = "TimeGenerated", type = "datetime" },
      { name = "ComputerName_s", type = "string" },
      { name = "ManagedDeviceID_g", type = "string" },
    ],
    [for i in range(1, 11) : { name = "InstalledApps${i}_s", type = "string" }],
    # App Usage columns, in the same order as main.bicep. Every _g column is
    # string, like ManagedDeviceID_g: a DCR stream has no guid type, and a guid
    # table column fails the DCR's transform check.
    [
      { name = "AppUsageEnabled_b", type = "boolean" },
      { name = "WatchingSince_t", type = "datetime" },
      { name = "AppUsageScriptVersion_s", type = "string" },
      { name = "MappingsVersion_s", type = "string" },
      { name = "CustomerMappingsHash_s", type = "string" },
      { name = "UnmatchedExeCount_d", type = "real" },
      { name = "ProfilesFound_d", type = "real" },
      { name = "ProfilesRead_d", type = "real" },
      { name = "AppUsageCollectionStatus_s", type = "string" },
    ],
    [for i in range(1, 11) : { name = "ExeUsage${i}_s", type = "string" }],
    [
      { name = "RunId_g", type = "string" },
      { name = "RowIndex_d", type = "real" },
      { name = "RowCount_d", type = "real" },
    ],
  )

  driver_columns = concat(
    [
      { name = "TimeGenerated", type = "datetime" },
      { name = "ComputerName_s", type = "string" },
      { name = "ManagedDeviceID_g", type = "string" },
    ],
    [for i in range(1, 11) : { name = "ListedDrivers${i}_s", type = "string" }],
  )

  # Map of table name => column schema, iterated for both the tables and the DCR.
  tables = {
    (local.device_table) = local.device_columns
    (local.app_table)    = local.app_columns
    (local.driver_table) = local.driver_columns
  }
}

# ==================================================
# Existing Log Analytics workspace
# ==================================================

data "azurerm_log_analytics_workspace" "law" {
  name                = var.workspace_name
  resource_group_name = var.workspace_resource_group_name
}

# ==================================================
# Custom _CL tables (azapi: azurerm cannot create custom-schema tables)
# ==================================================

resource "azapi_resource" "table" {
  for_each = local.tables

  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = each.key
  parent_id = data.azurerm_log_analytics_workspace.law.id

  # The provider's built-in schema check can lag the API; the body below is the
  # same shape main.bicep sends, so skip client-side validation.
  schema_validation_enabled = false

  body = {
    properties = {
      plan = "Analytics"
      schema = {
        name    = each.key
        columns = each.value
      }
    }
  }
}

# ==================================================
# Data Collection Endpoint
# ==================================================

resource "azurerm_monitor_data_collection_endpoint" "dce" {
  name                = var.dce_name
  resource_group_name = var.workspace_resource_group_name
  location            = data.azurerm_log_analytics_workspace.law.location
  description         = "DCE for PowerStacks Enhanced Inventory ingestion"
}

# ==================================================
# Data Collection Rule
# ==================================================

resource "azurerm_monitor_data_collection_rule" "dcr" {
  name                        = var.dcr_name
  resource_group_name         = var.workspace_resource_group_name
  location                    = data.azurerm_log_analytics_workspace.law.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.dce.id
  description                 = "PowerStacks Enhanced Inventory ingestion via Log Ingestion API"

  destinations {
    log_analytics {
      name                  = "la-destination"
      workspace_resource_id = data.azurerm_log_analytics_workspace.law.id
    }
  }

  dynamic "stream_declaration" {
    for_each = local.tables
    content {
      stream_name = "Custom-${stream_declaration.key}"

      dynamic "column" {
        for_each = stream_declaration.value
        content {
          name = column.value.name
          type = column.value.type
        }
      }
    }
  }

  dynamic "data_flow" {
    for_each = local.tables
    content {
      streams       = ["Custom-${data_flow.key}"]
      destinations  = ["la-destination"]
      transform_kql = "source | extend TimeGenerated = now()"
      output_stream = "Custom-${data_flow.key}"
    }
  }

  depends_on = [azapi_resource.table]
}

# ==================================================
# Optional RBAC: Monitoring Metrics Publisher on the DCR
# ==================================================

resource "azurerm_role_assignment" "dcr_publisher" {
  count = var.enterprise_app_object_id == "" ? 0 : 1

  scope                = azurerm_monitor_data_collection_rule.dcr.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = var.enterprise_app_object_id
  principal_type       = "ServicePrincipal"
}
