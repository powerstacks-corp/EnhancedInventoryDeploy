# Enhanced Inventory Deploy (Log Ingestion API)

This repository provides a **one-click Azure deployment** that sets up the required Azure resources for **PowerStacks Enhanced Inventory** using the **Azure Monitor Logs Ingestion API**.

The deployment creates (or reuses) a **Log Analytics Workspace**, configures required **custom tables**, and sets up the **Data Collection Endpoint (DCE)** and **Data Collection Rule (DCR)** used by the Enhanced Inventory Windows and macOS inventory scripts.

---

## 🚀 Deploy to Azure

Click the button below to deploy the required Azure resources:

<p>
  <a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fpowerstacks-corp%2FEnhancedInventoryDeploy%2Fmain%2Finfra%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fpowerstacks-corp%2FEnhancedInventoryDeploy%2Fmain%2Finfra%2FcreateUiDefinition.json">
    <img src="https://aka.ms/deploytoazurebutton" alt="Deploy to Azure">
  </a>
</p>

> ⚠️ **Important**  
> Before clicking **Deploy to Azure**, review the **Prerequisites** section below.  
> One required value must be obtained from the Azure portal.

---

## What this deployment sets up

- Log Analytics Workspace (new or existing)
- Custom Log Analytics tables:
  - `PowerStacksDeviceInventory_CL`
  - `PowerStacksAppInventory_CL`
  - `PowerStacksDriverInventory_CL`
- Data Collection Endpoint (DCE)
- Data Collection Rule (DCR) with one stream per table
- Outputs required by the inventory scripts:
  - **DCE Logs Ingestion URI**
  - **DCR Immutable ID**

See [Custom table schemas](#custom-table-schemas) below for the column layout of each table.

---

## Prerequisites (Required Before Deployment)

### 1. Create an Entra ID application

You must create an **Entra ID App Registration** that will be used by the Enhanced Inventory scripts to authenticate to Azure.

From the app registration, record:
- **Tenant ID**
- **Application (Client) ID**
- **Client Secret**

These values are used **by the inventory scripts**, not by the Azure deployment itself.

---

### 2. Copy the *Enterprise Application Object ID* (Required for RBAC)

The Azure deployment needs the **Object ID of the Enterprise Application (service principal)** so it can automatically assign permissions to the Data Collection Rule.

> ⚠️ This is **NOT** the Application (Client) ID.

#### How to find it in the Azure portal

1. Go to **https://entra.microsoft.com**
2. Navigate to **Applications → Enterprise applications**
3. Locate the application you created for Enhanced Inventory
   - You may search by **name** or filter by **Application ID**
4. Open the application and copy the **Object ID** from the Overview page

This value will be entered in the deployment wizard as:

**Enterprise App Object Id**

---

## Required permissions

### Azure permissions
The user deploying the template must be:
- **Owner**, or
- **Contributor + User Access Administrator**

### Entra ID permissions
The user creating the app registration must be able to:
- Create app registrations
- View Enterprise Applications

---

## Deployment options

### Option 1: Create a new Log Analytics workspace
Choose **Create a new workspace** and provide a workspace name.

### Option 2: Use an existing Log Analytics workspace
Choose **Use an existing workspace** and provide:
- Subscription ID
- Resource group name
- Workspace name

> This is commonly used when deploying alongside **Windows Update for Business Reports** or other shared workspaces.

---

## Deployment wizard input summary

During deployment you will be prompted for:

- Workspace selection (new or existing)
- Workspace details (if using existing)
- **Enterprise App Object Id** (recommended)

> If the **Enterprise App Object Id** is provided:
> - The deployment automatically assigns the required **Monitoring Metrics Publisher** role to the DCR  
> - No manual RBAC steps are required after deployment

If the field is left blank, permissions must be assigned manually.

---

## After deployment

From the **Deployment Outputs**, copy the following values:

- **DceURI**
- **DcrImmutableId**

These values are required by the Windows and macOS inventory scripts.

---

## Configure inventory scripts

### Windows
Configure the following settings in the Windows inventory script:

- `LogAPIMode = LogIngestionAPI`
- `TenantId`
- `ClientId`
- `ClientSecret`
- `DceURI`
- `DcrImmutableId`

### macOS
Configure the same values in the macOS inventory script:

- `LogAPIMode = LogIngestionAPI`
- `TenantId`
- `ClientId`
- `ClientSecret`
- `DceURI`
- `DcrImmutableId`

### App Usage

App Usage is part of the Windows inventory script. It writes only to `PowerStacksAppInventory_CL`: usage fields inside the installed-app entries, and the App Usage columns described in [PowerStacksAppInventory_CL](#powerstacksappinventory_cl). It uses the same DCE URI, DCR immutable ID, and Entra app registration as the rest of the inventory, so it needs no other Azure resources.

New deployments already have the App Usage columns. For a deployment made before App Usage, see [Add the App Usage columns to an existing deployment](#add-the-app-usage-columns-to-an-existing-deployment) before you turn metering on.

`PowerStacksAppUsage_CL` is a legacy table from the earlier prototype collector. App Usage doesn't use it. `postdeploy/New-PowerStacksInventoryTables.ps1` still creates it, pending a decision on whether to remove it; the **Deploy to Azure** template and Terraform don't create it.

---

## Add the App Usage columns to an existing deployment

Deployments made before App Usage have a `PowerStacksAppInventory_CL` table and DCR stream without the App Usage columns. Add them with `postdeploy/Update-PowerStacksAppInventorySchema.ps1` before you turn App Usage metering on.

The script changes only two things:

- It adds the missing App Usage columns to the `PowerStacksAppInventory_CL` table.
- It appends the missing App Usage columns to the `Custom-PowerStacksAppInventory_CL` stream declaration of the DCR.

Everything else in the DCR stays exactly as it was: the other streams, the data flows and their transformations, the destinations, the data collection endpoint, the managed identity, and the tags. After the update, the script reads the DCR again and stops with an error if anything other than the new columns changed.

### Before you begin

- You need the Azure CLI, signed in with `az login`. Azure Cloud Shell (PowerShell) already has it.
- Your account needs permission to write the workspace table and the DCR, for example **Contributor** on their resource groups.
- You need the full resource ID of the DCR. In the Azure portal, open the DCR, and then select **JSON View** on the **Overview** page. Or run:

  ```powershell
  az resource show --resource-group "<DCR_RESOURCE_GROUP>" --name "dcr-PowerStacksInventory" --resource-type "Microsoft.Insights/dataCollectionRules" --query id --output tsv
  ```

### Run the update

1. Download the script:

   ```powershell
   $repo = "powerstacks-corp/EnhancedInventoryDeploy"
   $raw  = "https://raw.githubusercontent.com/$repo/main/postdeploy/Update-PowerStacksAppInventorySchema.ps1"
   Invoke-WebRequest -Uri $raw -OutFile .\Update-PowerStacksAppInventorySchema.ps1
   ```

1. Preview the change. With `-WhatIf`, the script lists the columns it would add and changes nothing:

   ```powershell
   .\Update-PowerStacksAppInventorySchema.ps1 `
     -SubscriptionId "<WORKSPACE_SUBSCRIPTION_ID>" `
     -ResourceGroupName "<WORKSPACE_RESOURCE_GROUP>" `
     -WorkspaceName "<WORKSPACE_NAME>" `
     -DcrResourceId "<DCR_RESOURCE_ID>" `
     -WhatIf
   ```

1. Run the same command without `-WhatIf`.

1. **Wait 30 minutes before you turn metering on.** A DCR change takes about 30 minutes to reach every ingestion instance. Until then, uploads still succeed, but rows can lose the new columns without any error. A test row that keeps the new columns doesn't prove that every upload will, so wait the full 30 minutes.

The script is safe to run again. Columns that already exist are skipped, and a run that finds nothing to add changes nothing.

### Backups

Each run without `-WhatIf` first saves the table and the DCR as it read them, in the folder that holds the script (or the folder you pass with `-BackupDirectory`):

- `backup-<UTC yyyyMMddHHmmss>-table.json`
- `backup-<UTC yyyyMMddHHmmss>-dcr.json`

Keep the files from the run that made the change. You need its DCR backup to roll back.

### If the update stops partway

The script updates the table first, and the DCR second. If Azure rejects a step, the script stops with an error, and nothing after that step runs. If the table update succeeded and the DCR update failed, the table has extra columns that nothing uses yet, which is harmless. Fix the cause shown in the error, and then run the script again. It skips the table and completes the DCR.

### Roll back

Roll back in this order:

1. **Roll back the inventory script first.** Turn App Usage metering off, or redeploy the previous script version.
1. **Roll back the DCR second,** and only if the update damaged it. Wait until devices have stopped sending split runs first. A DCR without the run columns drops them, so the rows of a split run arrive as unrelated rows, and inventory for that device breaks.

To roll back the DCR, put the saved backup back with `-RollbackFrom`:

```powershell
.\Update-PowerStacksAppInventorySchema.ps1 `
  -SubscriptionId "<WORKSPACE_SUBSCRIPTION_ID>" `
  -ResourceGroupName "<WORKSPACE_RESOURCE_GROUP>" `
  -WorkspaceName "<WORKSPACE_NAME>" `
  -DcrResourceId "<DCR_RESOURCE_ID>" `
  -RollbackFrom ".\backup-<UTC yyyyMMddHHmmss>-dcr.json"
```

The script backs up the current DCR, puts the backup back, and checks that the DCR now matches it. It refuses a file that isn't a backup of that DCR. The table columns stay in place, and the previous inventory script ignores them. A rollback is also a DCR change, so it takes about 30 minutes to reach every ingestion instance.

### Compatibility

| Inventory script | Table and DCR | Result |
|---|---|---|
| Without App Usage | Without the App Usage columns | Today's behavior. |
| Without App Usage | With the App Usage columns | Unchanged. The App Usage columns stay empty. |
| With App Usage, metering off | Either | The same App Inventory rows as the script without App Usage. |
| With App Usage, metering on, run fits in one row | Without the App Usage columns | The usage fields inside `InstalledApps` arrive. The DCR drops the App Usage columns without an error. |
| With App Usage, metering on, run split across rows | Without the App Usage columns | **Not supported.** The DCR drops the run columns, so rows 2 and later arrive as ordinary rows that hold only part of the data, and inventory for that device breaks. |
| With App Usage, metering on | With the App Usage columns, after the 30-minute wait | Everything arrives. |

That's why turning metering on requires three things: this update, the 30-minute wait, and the BI for Intune release that reads split runs.

### Terraform deployments

For a deployment made with the Terraform module in `infra/terraform`, run `terraform plan` and `terraform apply` with the current module instead. Terraform adds the columns to the table and to the DCR stream. Review the plan first, because Terraform also reverts any DCR changes made outside Terraform. The 30-minute wait applies the same way.

---

## Verify the deployment (Optional)

Use the validation script:

- `LogIngestionAPI_CheckDCR_v2.0`

This script retrieves and displays the full DCR configuration and is useful for troubleshooting ingestion issues.

---

## Custom table schemas

The tables share a common identity header (`TimeGenerated`, `ComputerName_s`, `ManagedDeviceID_g`). Each table also carries the data specific to its inventory type.

### PowerStacksDeviceInventory_CL

| Column | Type |
|---|---|
| `TimeGenerated` | datetime |
| `ComputerName_s` | string |
| `ManagedDeviceID_g` | string (GUID) |
| `Microsoft365_b` | boolean |
| `Warranty_b` | boolean |
| `DeviceDetails1_s` ... `DeviceDetails10_s` | string |

The ten `DeviceDetails` slots carry inventory payloads serialized by the Windows / macOS inventory scripts. Each slot can hold up to the LAW string column limit (~32 KB).

### PowerStacksAppInventory_CL

| Column | Type |
|---|---|
| `TimeGenerated` | datetime |
| `ComputerName_s` | string |
| `ManagedDeviceID_g` | string (GUID) |
| `InstalledApps1_s` ... `InstalledApps10_s` | string |
| `AppUsageEnabled_b` | boolean |
| `WatchingSince_t` | datetime |
| `AppUsageScriptVersion_s` | string |
| `MappingsVersion_s` | string |
| `CustomerMappingsHash_s` | string |
| `UnmatchedExeCount_d` | real |
| `ProfilesFound_d` | real |
| `ProfilesRead_d` | real |
| `AppUsageCollectionStatus_s` | string |
| `ExeUsage1_s` ... `ExeUsage10_s` | string |
| `RunId_g` | string (GUID) |
| `RowIndex_d` | real |
| `RowCount_d` | real |

Same slot convention as device inventory. Each `InstalledApps` slot holds a chunk of the installed-application list.

The App Usage columns stay empty unless the Windows inventory script runs with App Usage metering on:

| Column | Description |
|---|---|
| `AppUsageEnabled_b` | Metering was on for this run. |
| `WatchingSince_t` | Earliest usage data the device has. |
| `AppUsageScriptVersion_s` | Inventory script version. |
| `MappingsVersion_s` | Version of the PowerStacks mappings the run used. |
| `CustomerMappingsHash_s` | SHA-256 hash of the customer mappings file the run used. Empty when the file was absent or invalid. |
| `UnmatchedExeCount_d` | Number of executable entries that didn't match an installed app. |
| `ProfilesFound_d`, `ProfilesRead_d` | User profiles on the device, and how many of them the run read. The difference is the coverage gap. |
| `AppUsageCollectionStatus_s` | `OK`, or a list of problems in the form `Token[:detail]`, separated by `; `. |
| `ExeUsage1_s` ... `ExeUsage10_s` | Per-executable usage evidence, in the same slot convention as `InstalledApps`. |
| `RunId_g` | One ID per run. Every row of the run carries it. |
| `RowIndex_d`, `RowCount_d` | This row's position in the run, and the run's row count. Both are `1` when the run fits in one row. A run too large for one row is split across several rows that share a `RunId_g`. |

`RunId_g` is declared `string` in both the table and the DCR, like `ManagedDeviceID_g`. A DCR stream has no GUID type, and a GUID table column fails the DCR's transform check.

New deployments from this repository (the **Deploy to Azure** button, `infra/main.bicep`, Terraform, and `postdeploy/New-PowerStacksInventoryTables.ps1`) include these columns. To add them to an existing deployment, see [Add the App Usage columns to an existing deployment](#add-the-app-usage-columns-to-an-existing-deployment).

### PowerStacksDriverInventory_CL

| Column | Type |
|---|---|
| `TimeGenerated` | datetime |
| `ComputerName_s` | string |
| `ManagedDeviceID_g` | string (GUID) |
| `ListedDrivers1_s` ... `ListedDrivers10_s` | string |

Same slot convention. Each `ListedDrivers` slot holds a chunk of the driver list.

### PowerStacksAppUsage_CL (legacy)

This table is from the earlier prototype collector and is no longer used: App Usage writes only to `PowerStacksAppInventory_CL`. `postdeploy/New-PowerStacksInventoryTables.ps1` still creates it, pending a decision on whether to remove it. Its schema is listed here for reference only.

| Column | Type | Description |
|---|---|---|
| `TimeGenerated` | datetime | Ingestion timestamp. |
| `ComputerName_s` | string | Device hostname. |
| `ManagedDeviceID_g` | string (GUID) | Intune managed device ID. Joins to `PowerStacksDeviceInventory_CL`. |
| `UserSid_s` | string | Raw Windows SID of the user the row is attributed to. |
| `UserSidType_s` | string | One of `CloudOnly`, `Hybrid`, `System`, `Service`, `Unknown`. |
| `AadUserId_g` | string (GUID) | Microsoft Entra object ID. Decoded from the SID locally for cloud-only users. Populated from `dsregcmd` for the currently signed-in hybrid user. Empty for unloaded hybrid profiles and for service accounts. |
| `UPN_s` | string | User principal name resolved from the IdentityStore cache. |
| `UserName_s` | string | Local user name. |
| `ResolvedAppName_s` | string | Add/Remove Programs display name when the exe could be resolved, otherwise empty. |
| `Publisher_s` | string | Add/Remove Programs publisher when known. |
| `ProductCode_g` | string (GUID) | MSI product code when the exe maps to an MSI-installed product. |
| `ExeInfo_s` | string | Exe basename for Win32 rows, or the SRUM-decorated AppX identifier for UWP rows. |
| `ResolutionSource_s` | string | One of `ARP`, `ARP (ambiguous)`, `UWP`, `None`. Indicates how the exe was resolved. |
| `LastUsedTime` | datetime | Most recent time the user touched the app (high-water mark; never regresses). |
| `FirstSeen` | datetime | First time this (user, app) ledger entry was written. |
| `InFocusSeconds` | integer | Accumulated in-focus or tracked-activity time. |

The prototype schema was per user and app rather than per device.

---

## Repository contents

- `infra/main.bicep`: Source Bicep template
- `infra/main.json`: Compiled ARM template used by the portal
- `infra/createUiDefinition.json`: Portal wizard for the Deploy to Azure button (validates the workspace name and collects the DCE/DCR names and optional Enterprise Application Object ID)
- `infra/terraform`: Terraform equivalent of the template, for an existing workspace
- `postdeploy/New-PowerStacksInventoryTables.ps1`: Creates or updates the custom tables in an existing workspace
- `postdeploy/Update-PowerStacksAppInventorySchema.ps1`: Adds the App Usage columns to an existing deployment, with backup and rollback
- `postdeploy/tests`: Offline Pester tests for the updater

---

## Support

For questions or issues:
- Open an issue in this repository
- Or contact **PowerStacks Support**
