# Log Ingestion API – Customer Deployment Guide

## Overview

This guide documents an end-to-end, customer-run deployment of PowerStacks Enhanced Inventory using the Azure Monitor Logs Ingestion API. All steps can be completed using the Azure Portal.

## Before You Begin

**Azure permissions required:**

- **Contributor** or **Owner** on the target subscription or resource group
- **User Access Administrator** or **Owner** to assign roles (only required if you want the deployment to automatically assign DCR permissions)

**Microsoft Entra permissions required:**

- **Application Administrator** or **Global Administrator**

## Step 1 – Create the App Registration

1. In the [Azure Portal](https://portal.azure.com), navigate to **Microsoft Entra ID** > **App registrations** > **New registration**.
2. Enter a name (e.g., `PowerStacks-EnhancedInventory`) and register the app.
3. From the App Registration overview, record the following:
   - **Application (Client) ID**
   - **Directory (Tenant) ID**
4. Navigate to **Certificates & secrets** > **New client secret**. Create a secret and record the **Value** (not the Secret ID).

## Step 2 – Get the Enterprise Application Object ID

1. In the Azure Portal, navigate to **Microsoft Entra ID** > **Enterprise applications**.
2. Search for the app you just registered in Step 1.
3. Record the **Object ID** from the Enterprise Application overview page.

> **Important:** The Object ID from Enterprise Applications is different from the one shown in App Registrations. The ARM template requires the **Enterprise Application Object ID** (the service principal Object ID), not the App Registration Object ID.

## Step 3 – Deploy Azure Resources

1. Use the **Deploy to Azure** button from the repository README.
2. Select your target subscription and resource group.
3. Choose whether to create a new Log Analytics workspace or use an existing one.
4. When prompted for **Enterprise App Object Id**, paste the Object ID from Step 2.

> **Note:** The Enterprise App Object Id field is optional. If provided, the deployment automatically assigns the required permissions (Step 4). If left blank, you must assign permissions manually after deployment.

## Step 4 – Automatic RBAC Assignment

If the Enterprise Application Object ID was provided during deployment, the template automatically assigns the **Monitoring Metrics Publisher** role to the service principal on the Data Collection Rule (DCR).

If you left the field blank, manually assign the role:

1. Navigate to the deployed **Data Collection Rule** in the Azure Portal.
2. Go to **Access control (IAM)** > **Add role assignment**.
3. Select the **Monitoring Metrics Publisher** role.
4. Assign it to the Enterprise Application (service principal) you created in Step 1.

## Step 5 – Capture Deployment Outputs

After deployment completes:

1. Navigate to the resource group > **Deployments** > select the deployment.
2. Go to the **Outputs** tab and record:
   - **DceURI** – the Data Collection Endpoint URI
   - **DcrImmutableId** – the immutable ID of the Data Collection Rule

## Step 6 – Configure Inventory Scripts

Update the Windows and/or macOS inventory scripts with the following values:

| Variable | Source |
|----------|--------|
| `TenantId` | Step 1 – Directory (Tenant) ID |
| `ClientId` | Step 1 – Application (Client) ID |
| `ClientSecret` | Step 1 – Client Secret Value |
| `DceURI` | Step 5 – Deployment Output |
| `DcrImmutableId` | Step 5 – Deployment Output |

## Step 7 – Deploy as Intune Remediation

1. In the [Intune admin center](https://intune.microsoft.com), navigate to **Devices** > **Remediations**.
2. Create a new remediation and upload the inventory script as the **detection script**.
3. Schedule it to run **once per day**.

## Optional – Validate the Deployment

Run the `LogIngestionAPI_CheckDCR` script to retrieve and review the full Data Collection Rule configuration for troubleshooting purposes.

## Summary Checklist

- [ ] App Registration created (Step 1)
- [ ] Client ID, Tenant ID, and Client Secret recorded (Step 1)
- [ ] Enterprise Application Object ID recorded (Step 2)
- [ ] Azure resources deployed (Step 3)
- [ ] Enterprise App Object ID supplied during deployment, or RBAC assigned manually (Step 4)
- [ ] DceURI and DcrImmutableId captured from deployment outputs (Step 5)
- [ ] Inventory scripts configured with all five values (Step 6)
- [ ] Remediation deployed in Intune (Step 7)
