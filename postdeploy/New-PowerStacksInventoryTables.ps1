<#
.SYNOPSIS
  Creates (or updates) the PowerStacks Enhanced Inventory custom tables in an existing Log Analytics workspace.

.DESCRIPTION
  Creates/updates ONLY the following Log Analytics tables:
    - PowerStacksDeviceInventory_CL
    - PowerStacksAppInventory_CL
    - PowerStacksDriverInventory_CL
    - PowerStacksAppUsage_CL

  This script does not create a workspace, DCR, DCE, or role assignments.

  Requires:
    - Az.Accounts
    - Az.Resources
  And an authenticated Azure context with permissions to write workspace tables.

.EXAMPLE
  .\New-PowerStacksInventoryTables.ps1 -SubscriptionId "<subId>" -ResourceGroupName "<rg>" -WorkspaceName "<lawName>"

.NOTES
  Author: John Marcum (PJM)
  Date: 2026-01-20

########### LEGAL DISCLAIMER ###########
This script is provided "as is" without warranty of any kind, either express or implied, including but not limited
to the implied warranties of merchantability and/or fitness for a particular purpose. The author shall not be
liable for any damages arising from the use of this script.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$SubscriptionId,

  [Parameter(Mandatory)]
  [string]$ResourceGroupName,

  [Parameter(Mandatory)]
  [string]$WorkspaceName
)

# Optional hard-coding for packaged runs
# $SubscriptionId   = '00000000-0000-0000-0000-000000000000'
# $ResourceGroupName = 'rg-loganalytics'
# $WorkspaceName     = 'law-prod'


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-AzModules {
  [CmdletBinding()]
  param(
    [string[]]$Required = @('Az.Accounts','Az.Resources')
  )

  # Make sure we can install modules if needed
  try {
    $null = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction Stop
  } catch {
    Write-Host "NuGet provider not found. Installing NuGet provider..."
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
  }

  foreach ($m in $Required) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
      Write-Host "Required module '$m' is not installed. Installing..."
      try {
        Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
      } catch {
        throw "Failed to install module '$m'. Error: $($_.Exception.Message)"
      }
    }

    # Import so commands are available in this session
    try {
      Import-Module -Name $m -Force -ErrorAction Stop
    } catch {
      throw "Module '$m' is installed but failed to import. Error: $($_.Exception.Message)"
    }
  }
}

function Ensure-AzLogin {
  [CmdletBinding()]
  param(
    # Use device code flow when running headless / no embedded browser
    [switch]$UseDeviceCode
  )

  $ctx = $null
  try {
    $ctx = Get-AzContext -ErrorAction Stop
  } catch {
    $ctx = $null
  }

  $needsLogin = $false
  if (-not $ctx) {
    $needsLogin = $true
  } else {
    # Context exists but token may be missing/expired/unusable; test with a lightweight call
    try {
      $null = Get-AzSubscription -ErrorAction Stop | Select-Object -First 1
    } catch {
      $needsLogin = $true
    }
  }

  if ($needsLogin) {
    Write-Host "No valid Azure session found. Connecting to Azure..."
    try {
      if ($UseDeviceCode) {
        Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop | Out-Null
      } else {
        Connect-AzAccount -ErrorAction Stop | Out-Null
      }
    } catch {
      throw "Failed to authenticate to Azure. Error: $($_.Exception.Message)"
    }
  } else {
    Write-Host "Azure session detected."
  }
}

function New-OrUpdate-WorkspaceTable {
  param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [Parameter(Mandatory)][string]$TableName,
    [Parameter(Mandatory)][array]$Columns
  )

  $apiVersion = '2022-10-01'
  $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/tables/$TableName"

  $body = @{
    properties = @{
      plan   = 'Analytics'
      schema = @{
        name    = $TableName
        columns = $Columns
      }
    }
  } | ConvertTo-Json -Depth 20

  Write-Host "Creating/updating table: $TableName"
  $null = Invoke-AzRestMethod -Method PUT -Path "${resourceId}?api-version=${apiVersion}" -Payload $body
}

Assert-AzModules
Ensure-AzLogin
Set-AzContext -Subscription $SubscriptionId | Out-Null

# ----------------------------
# Table names
# ----------------------------
$DeviceTableName   = 'PowerStacksDeviceInventory_CL'
$AppTableName      = 'PowerStacksAppInventory_CL'
$DriverTableName   = 'PowerStacksDriverInventory_CL'
$AppUsageTableName = 'PowerStacksAppUsage_CL'

# ----------------------------
# Column schemas (match template)
# ----------------------------
$DeviceColumns = @(
  @{ name = 'TimeGenerated';       type = 'datetime' },
  @{ name = 'ComputerName_s';      type = 'string'   },
  @{ name = 'ManagedDeviceID_g';   type = 'string'   },
  @{ name = 'Microsoft365_b';      type = 'boolean'  },
  @{ name = 'Warranty_b';          type = 'boolean'  },
  @{ name = 'DeviceDetails1_s';    type = 'string'   },
  @{ name = 'DeviceDetails2_s';    type = 'string'   },
  @{ name = 'DeviceDetails3_s';    type = 'string'   },
  @{ name = 'DeviceDetails4_s';    type = 'string'   },
  @{ name = 'DeviceDetails5_s';    type = 'string'   },
  @{ name = 'DeviceDetails6_s';    type = 'string'   },
  @{ name = 'DeviceDetails7_s';    type = 'string'   },
  @{ name = 'DeviceDetails8_s';    type = 'string'   },
  @{ name = 'DeviceDetails9_s';    type = 'string'   },
  @{ name = 'DeviceDetails10_s';   type = 'string'   }
)

$AppColumns = @(
  @{ name = 'TimeGenerated';       type = 'datetime' },
  @{ name = 'ComputerName_s';      type = 'string'   },
  @{ name = 'ManagedDeviceID_g';   type = 'string'   },
  @{ name = 'InstalledApps1_s';    type = 'string'   },
  @{ name = 'InstalledApps2_s';    type = 'string'   },
  @{ name = 'InstalledApps3_s';    type = 'string'   },
  @{ name = 'InstalledApps4_s';    type = 'string'   },
  @{ name = 'InstalledApps5_s';    type = 'string'   },
  @{ name = 'InstalledApps6_s';    type = 'string'   },
  @{ name = 'InstalledApps7_s';    type = 'string'   },
  @{ name = 'InstalledApps8_s';    type = 'string'   },
  @{ name = 'InstalledApps9_s';    type = 'string'   },
  @{ name = 'InstalledApps10_s';   type = 'string'   },
  # App Usage columns. Every _g column is string, like ManagedDeviceID_g: a DCR stream has
  # no guid type, and a guid table column fails the DCR's transform check.
  @{ name = 'AppUsageEnabled_b';           type = 'boolean'  },
  @{ name = 'WatchingSince_t';             type = 'datetime' },
  @{ name = 'AppUsageScriptVersion_s';     type = 'string'   },
  @{ name = 'MappingsVersion_s';           type = 'string'   },
  @{ name = 'CustomerMappingsHash_s';      type = 'string'   },
  @{ name = 'UnmatchedExeCount_d';         type = 'real'     },
  @{ name = 'ProfilesFound_d';             type = 'real'     },
  @{ name = 'ProfilesRead_d';              type = 'real'     },
  @{ name = 'AppUsageCollectionStatus_s';  type = 'string'   },
  @{ name = 'ExeUsage1_s';                 type = 'string'   },
  @{ name = 'ExeUsage2_s';                 type = 'string'   },
  @{ name = 'ExeUsage3_s';                 type = 'string'   },
  @{ name = 'ExeUsage4_s';                 type = 'string'   },
  @{ name = 'ExeUsage5_s';                 type = 'string'   },
  @{ name = 'ExeUsage6_s';                 type = 'string'   },
  @{ name = 'ExeUsage7_s';                 type = 'string'   },
  @{ name = 'ExeUsage8_s';                 type = 'string'   },
  @{ name = 'ExeUsage9_s';                 type = 'string'   },
  @{ name = 'ExeUsage10_s';                type = 'string'   },
  @{ name = 'RunId_g';                     type = 'string'   },
  @{ name = 'RowIndex_d';                  type = 'real'     },
  @{ name = 'RowCount_d';                  type = 'real'     }
)

$DriverColumns = @(
  @{ name = 'TimeGenerated';       type = 'datetime' },
  @{ name = 'ComputerName_s';      type = 'string'   },
  @{ name = 'ManagedDeviceID_g';   type = 'string'   },
  @{ name = 'ListedDrivers1_s';    type = 'string'   },
  @{ name = 'ListedDrivers2_s';    type = 'string'   },
  @{ name = 'ListedDrivers3_s';    type = 'string'   },
  @{ name = 'ListedDrivers4_s';    type = 'string'   },
  @{ name = 'ListedDrivers5_s';    type = 'string'   },
  @{ name = 'ListedDrivers6_s';    type = 'string'   },
  @{ name = 'ListedDrivers7_s';    type = 'string'   },
  @{ name = 'ListedDrivers8_s';    type = 'string'   },
  @{ name = 'ListedDrivers9_s';    type = 'string'   },
  @{ name = 'ListedDrivers10_s';   type = 'string'   }
)

$AppUsageColumns = @(
  @{ name = 'TimeGenerated';       type = 'datetime' },
  @{ name = 'ComputerName_s';      type = 'string'   },
  @{ name = 'ManagedDeviceID_g';   type = 'string'   },
  @{ name = 'UserSid_s';           type = 'string'   },
  @{ name = 'UserSidType_s';       type = 'string'   },
  @{ name = 'AadUserId_g';         type = 'string'   },
  @{ name = 'UPN_s';               type = 'string'   },
  @{ name = 'UserName_s';          type = 'string'   },
  @{ name = 'ResolvedAppName_s';   type = 'string'   },
  @{ name = 'Publisher_s';         type = 'string'   },
  @{ name = 'ProductCode_g';       type = 'string'   },
  @{ name = 'ExeInfo_s';           type = 'string'   },
  @{ name = 'ResolutionSource_s'; type = 'string'   },
  @{ name = 'LastUsedTime';        type = 'datetime' },
  @{ name = 'FirstSeen';           type = 'datetime' },
  @{ name = 'InFocusSeconds';      type = 'int'      }
)

# ----------------------------
# Create/update tables
# ----------------------------
New-OrUpdate-WorkspaceTable -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -TableName $DeviceTableName   -Columns $DeviceColumns
New-OrUpdate-WorkspaceTable -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -TableName $AppTableName      -Columns $AppColumns
New-OrUpdate-WorkspaceTable -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -TableName $DriverTableName   -Columns $DriverColumns
New-OrUpdate-WorkspaceTable -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName -TableName $AppUsageTableName -Columns $AppUsageColumns

Write-Host "Done. Tables ensured in workspace '$WorkspaceName'."
