# Enhanced Inventory: Terraform deployment

A Terraform equivalent of the one-click ARM template (`infra/main.bicep`), for teams whose standard is Terraform. It provisions the same Azure resources against an **existing** Log Analytics workspace:

- The three custom tables: `PowerStacksDeviceInventory_CL`, `PowerStacksAppInventory_CL`, `PowerStacksDriverInventory_CL`.
- A Data Collection Endpoint (DCE).
- A Data Collection Rule (DCR) with a per-table stream declaration and the `TimeGenerated` transform.
- Optionally, the **Monitoring Metrics Publisher** role on the DCR for the Enterprise Application that writes inventory.

The `DceURI` and `DcrImmutableId` outputs are what you put into the inventory script, the same values the ARM template produced.

## Providers

- `hashicorp/azurerm` (~> 4.0) for the DCE, DCR, and role assignment.
- `azure/azapi` (~> 2.0) for the three custom `_CL` tables. The `azurerm` provider cannot create custom-schema Log Analytics tables, so those go through `azapi`. If your organization vets providers, note that `azapi` is Microsoft's official provider (`Azure/terraform-provider-azapi`) and calls the same Azure Resource Manager API the ARM template does.

## Prerequisites

- An existing Log Analytics workspace. If Windows Update for Business reports created one, use that same workspace, both add-ons share one workspace.
- Terraform >= 1.5, and Azure credentials with rights to create the DCE, DCR, and tables in the workspace's resource group (and to assign the role, if you set `enterprise_app_object_id`).
- A subscription for the `azurerm` provider: set `ARM_SUBSCRIPTION_ID`, or `subscription_id` in `versions.tf`.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: workspace_name, workspace_resource_group_name,
# and optionally enterprise_app_object_id

terraform init
terraform plan
terraform apply

# Grab the values the inventory script needs:
terraform output DceURI
terraform output DcrImmutableId
```

Then set `DceURI` and `DcrImmutableId` in the inventory script per [Set up Enhanced Inventory](https://powerstacks.com/docs/bi-for-intune/installation/custom-inventory/).

## Notes

- The DCE and DCR are created in the workspace's resource group and region, so they stay co-located with the workspace.
- If you leave `enterprise_app_object_id` blank, assign **Monitoring Metrics Publisher** to your Enterprise Application on the DCR manually afterward (DCR > Access control (IAM) > Add role assignment).
- The table and stream schemas are defined once in `main.tf` (`locals`) and reused, matching `main.bicep`. If PowerStacks changes the inventory schema in a future release, update the column lists here to match.
- The module includes the App Usage columns on `PowerStacksAppInventory_CL`. Applying it to a deployment made with an earlier version adds them to the table and to the DCR stream. A DCR change takes about 30 minutes to reach every ingestion instance, so wait the full 30 minutes after `terraform apply` before you turn App Usage metering on. See the main README for the rollback order.
