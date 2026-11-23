# Post-Deployment Onboarding  
**PowerStacks Enhanced Inventory**

This folder contains the **post-deployment onboarding script**. It is optional. It automates the identity, permissions, and value-capture steps that follow the Azure deployment. Use it when you deploy without the portal **Deploy to Azure** button (for example, via the Azure CLI or a pipeline), or when you would rather automate those steps than do them by hand as described in the main deployment guide.

The Azure deployment creates all required **Azure resources** (Log Analytics workspace, tables, DCR, DCE).  
This script completes the **identity, permissions, and validation** steps that cannot be handled reliably by ARM/Bicep alone.

---

## Architecture overview

**Deploy to Azure**
→ Creates Azure resources (workspace, tables, DCE, DCR)  
**Post-deploy onboarding**
→ Creates identity, assigns permissions, validates ingestion

This two-step model is intentional and provides the most reliable experience across tenants.

---

## When do I need to run this?

If you choose this path, run the script **once** after the deployment shows **“Deployment complete”** in the Azure Portal.

You do **not** need to rerun this script unless:
- You rotate the client secret
- You redeploy the DCR and want to reassign permissions

---

## Recommended: Run from Azure Cloud Shell (easiest)

Using **Azure Cloud Shell** avoids installing any tools locally and is the simplest option.

### Step 1: Open Cloud Shell
1. In the Azure Portal, navigate to the **Resource Group** used for deployment
2. Select the **Cloud Shell** icon (top-right)
3. Choose **PowerShell**

---

### Step 2: Download the onboarding script

```powershell
$repo = "powerstacks-corp/EnhancedInventoryDeploy"
$raw  = "https://raw.githubusercontent.com/$repo/main/postdeploy/Onboard-EnhancedInventory.ps1"

Invoke-WebRequest -Uri $raw -OutFile .\Onboard-EnhancedInventory.ps1
```

---

### Step 3: Run the script (latest deployment is used automatically)

```powershell
.\Onboard-EnhancedInventory.ps1 `
  -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
  -ResourceGroupName "<RESOURCE_GROUP_NAME>" `
  -CreateAppRegistration `
  -AssignRbac
```

> By default, the script automatically targets the **latest successful deployment** in the resource group.

---

## Optional: Specify a deployment explicitly

If the resource group contains multiple deployments and you want to target a specific one:

```powershell
.\Onboard-EnhancedInventory.ps1 `
  -SubscriptionId "<YOUR_SUBSCRIPTION_ID>" `
  -ResourceGroupName "<RESOURCE_GROUP_NAME>" `
  -DeploymentName "<DEPLOYMENT_NAME>" `
  -CreateAppRegistration `
  -AssignRbac
```

---

## What the script does

When run with `-CreateAppRegistration` and `-AssignRbac`, the script performs the following actions:

1. Reads outputs from the Azure deployment:
   - Log Ingestion Endpoint (DCE URI)
   - Data Collection Rule Immutable ID
   - Workspace information
2. Creates an **Entra ID App Registration** for log ingestion
3. Generates a **client secret**
4. Assigns the **Monitoring Metrics Publisher** role on the Data Collection Rule
5. Displays the values required by the inventory scripts

---

## Script output (important)

At the end of execution, the script prints a block similar to the following:

```
============================================================
Enhanced Inventory - Values to paste into inventory scripts
============================================================
TenantId:       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
ClientId:       xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
ClientSecret:   ************************************
DceURI:         https://<region>.ingest.monitor.azure.com
DcrImmutableId: dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
============================================================
```

Use these values in:
- `Windows_Custom_Inventory_v2.0.ps1`
- `Mac_Custom_Inventory_v2.0.ps1`

---

## Required permissions

The user running the script must have:

- Permission to **create App Registrations** in Entra ID  
  *(Application Administrator, Cloud Application Administrator, or Global Administrator)*
- Permission to **create role assignments** on the Data Collection Rule  
  *(Owner or User Access Administrator at the resource group level)*

### If RBAC assignment fails
You can assign permissions manually:

1. Azure Portal → **Monitor** → **Data Collection Rules**
2. Open your DCR
3. Select **Access control (IAM)**
4. Add role assignment → **Monitoring Metrics Publisher**
5. Assign to the ingestion **Enterprise Application**

---

## Local execution (optional)

If you prefer to run the script locally instead of Cloud Shell:

```powershell
Install-Module Az -Scope CurrentUser -Force -AllowClobber
```

Then run the same commands shown above from a PowerShell prompt.

---

## Validation

After onboarding is complete and inventory scripts are deployed, validate ingestion by querying any of the three tables that should be receiving data:

```kql
PowerStacksDeviceInventory_CL | take 10
PowerStacksAppInventory_CL    | take 10
PowerStacksDriverInventory_CL | take 10
```

If rows appear, ingestion is working. The Windows and macOS inventory scripts populate these tables. App Usage, when metering is on, writes only to `PowerStacksAppInventory_CL`. `PowerStacksAppUsage_CL` is a legacy table from the earlier prototype collector and is no longer used (see the App Usage section of the main README).

---

## Next steps

1. Update the Windows and macOS inventory scripts using the printed values
2. Deploy the scripts using Intune or your preferred device management tool

Migrating from the legacy HTTP Data Collector API? Classic-to-DCR table migration is handled by a separate script, `migrate/Migrate-PowerStacksClassicTables.ps1`. Run it once before deploying (see the main deployment guide).

Future versions of this onboarding script may add:
- Automated Intune Proactive Remediation deployment
- Optional validation checks

---

## Troubleshooting

- If no deployment is found, specify `-DeploymentName`
- If RBAC assignment fails, verify permissions or assign the role manually
- If ingestion fails, verify DCR Immutable ID and DCE URI were copied correctly
