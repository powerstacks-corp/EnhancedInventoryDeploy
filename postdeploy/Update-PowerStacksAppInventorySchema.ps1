#Requires -Version 5.1
<#
.SYNOPSIS
  Adds the App Usage columns to an existing PowerStacks Enhanced Inventory deployment.

.DESCRIPTION
  Adds the 22 App Usage columns to the PowerStacksAppInventory_CL table and to the
  Custom-PowerStacksAppInventory_CL stream of the data collection rule (DCR). Use it on
  deployments made before App Usage. New deployments from this repository already have
  the columns.

  The script:
    1. Reads the table and the DCR, and saves both as backup files named
       backup-<UTC yyyyMMddHHmmss>-table.json and backup-<UTC yyyyMMddHHmmss>-dcr.json.
    2. Adds the missing columns to the table, and waits until the table shows them.
    3. Builds the new DCR from the one it read, appending the missing columns to the
       Custom-PowerStacksAppInventory_CL stream declaration. Every other part of the DCR
       (other streams, data flows and their transformations, destinations, the data
       collection endpoint, identity, and tags) is sent back exactly as read.
    4. Updates the DCR, then reads it again and checks that nothing else changed.

  The script is safe to run again. Columns that already exist are skipped, and a run that
  finds nothing to add changes nothing. If an earlier run updated the table but not the
  DCR, running it again completes the DCR.

  Use -RollbackFrom to put a saved DCR backup back. Roll back the inventory script first
  (turn metering off, or redeploy the previous script version), and the DCR second. Table
  columns are left in place; the previous script ignores them.

  A DCR change takes about 30 minutes to reach every ingestion instance. Until then, calls
  still succeed, but rows can lose the new columns without any error. Wait the full 30
  minutes after the DCR update before you turn metering on.

  Requires the Azure CLI, signed in (az login) with an account that can write the
  workspace table and the DCR.

.PARAMETER SubscriptionId
  Subscription of the Log Analytics workspace.

.PARAMETER ResourceGroupName
  Resource group of the Log Analytics workspace.

.PARAMETER WorkspaceName
  Name of the Log Analytics workspace that holds PowerStacksAppInventory_CL.

.PARAMETER DcrResourceId
  Full resource ID of the Enhanced Inventory DCR, for example
  /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Insights/dataCollectionRules/dcr-PowerStacksInventory

.PARAMETER RollbackFrom
  Path of a DCR backup file (backup-<time>-dcr.json) to put back. The current DCR is
  backed up first.

.PARAMETER BackupDirectory
  Folder for the backup files. Defaults to the folder that holds this script.

.PARAMETER TableName
  The table the DCR writes the Custom-PowerStacksAppInventory_CL stream to. Defaults to
  PowerStacksAppInventory_CL; change it only for a test table. The script refuses to run when
  the DCR's data flow for the stream writes to a different table.

.EXAMPLE
  .\Update-PowerStacksAppInventorySchema.ps1 -SubscriptionId "<subId>" -ResourceGroupName "<rg>" -WorkspaceName "<lawName>" -DcrResourceId "<dcrResourceId>" -WhatIf

.EXAMPLE
  .\Update-PowerStacksAppInventorySchema.ps1 -SubscriptionId "<subId>" -ResourceGroupName "<rg>" -WorkspaceName "<lawName>" -DcrResourceId "<dcrResourceId>"

.EXAMPLE
  .\Update-PowerStacksAppInventorySchema.ps1 -SubscriptionId "<subId>" -ResourceGroupName "<rg>" -WorkspaceName "<lawName>" -DcrResourceId "<dcrResourceId>" -RollbackFrom .\backup-20261122181643-dcr.json

.NOTES
  ########### LEGAL DISCLAIMER ###########
  This script is provided "as is" without warranty of any kind, either express or implied, including but not limited
  to the implied warranties of merchantability and/or fitness for a particular purpose. The author shall not be
  liable for any damages arising from the use of this script.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)]
  [string]$SubscriptionId,

  [Parameter(Mandatory)]
  [string]$ResourceGroupName,

  [Parameter(Mandatory)]
  [string]$WorkspaceName,

  [Parameter(Mandatory)]
  [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Insights/dataCollectionRules/[^/]+$')]
  [string]$DcrResourceId,

  [string]$RollbackFrom,

  [string]$BackupDirectory = $PSScriptRoot,

  [ValidatePattern('^[A-Za-z0-9_]+_CL$')]
  [string]$TableName = 'PowerStacksAppInventory_CL'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The stream the inventory script posts to. Its data flow writes to $TableName.
$StreamName = 'Custom-PowerStacksAppInventory_CL'
$TableApiVersion = '2022-10-01'
$DcrApiVersion   = '2024-03-11'

# The App Usage columns, in the order new deployments declare them (infra/main.bicep).
# Every _g column is string in both the table and the DCR stream, like ManagedDeviceID_g:
# a DCR stream has no guid type, and a guid table column fails the DCR's transform check.
$AppUsageColumns = @(
  [ordered]@{ name = 'AppUsageEnabled_b';          type = 'boolean'  }
  [ordered]@{ name = 'WatchingSince_t';            type = 'datetime' }
  [ordered]@{ name = 'AppUsageScriptVersion_s';    type = 'string'   }
  [ordered]@{ name = 'MappingsVersion_s';          type = 'string'   }
  [ordered]@{ name = 'CustomerMappingsHash_s';     type = 'string'   }
  [ordered]@{ name = 'UnmatchedExeCount_d';        type = 'real'     }
  [ordered]@{ name = 'ProfilesFound_d';            type = 'real'     }
  [ordered]@{ name = 'ProfilesRead_d';             type = 'real'     }
  [ordered]@{ name = 'AppUsageCollectionStatus_s'; type = 'string'   }
)
foreach ($i in 1..10) { $AppUsageColumns += [ordered]@{ name = "ExeUsage$($i)_s"; type = 'string' } }
$AppUsageColumns += [ordered]@{ name = 'RunId_g';    type = 'string' }
$AppUsageColumns += [ordered]@{ name = 'RowIndex_d'; type = 'real'   }
$AppUsageColumns += [ordered]@{ name = 'RowCount_d'; type = 'real'   }

# Server-set properties that a GET returns and a PUT must not send.
$DcrReadOnlyTop        = @('id', 'name', 'type', 'etag', 'systemData')
$DcrReadOnlyProperties = @('immutableId', 'provisioningState', 'metadata', 'endpoints')
$TableColumnReadOnly   = @('isDefaultDisplay', 'isHidden')

$TableWaitSeconds = 300
$TablePollSeconds = 10

# --------------------------------------------------
# Helpers
# --------------------------------------------------

function Write-Utf8File([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Utf8File([string]$Path) {
  [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, [System.Text.Encoding]::UTF8)
}

function Invoke-AzCli {
  # Runs az and throws when it fails. az writes warnings to stderr, so stderr alone is not
  # treated as failure; the exit code is.
  param([Parameter(Mandatory)][string]$Step, [Parameter(Mandatory)][string[]]$Arguments)
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & az @Arguments 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
  if ($code -ne 0) {
    $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    throw "$Step failed (az exit code $code). Nothing after this step was changed. az output:$([Environment]::NewLine)$text"
  }
}

function Get-ArmText([string]$Step, [string]$Url) {
  $file = [System.IO.Path]::GetTempFileName()
  try {
    Invoke-AzCli -Step $Step -Arguments @('rest', '--method', 'get', '--url', $Url, '--output-file', $file, '--only-show-errors')
    $text = Read-Utf8File $file
    if ([string]::IsNullOrWhiteSpace($text)) { throw "$Step returned an empty response." }
    return $text
  } finally {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue -WhatIf:$false
  }
}

function Send-ArmBody([string]$Step, [string]$Method, [string]$Url, [string]$Body) {
  $file = [System.IO.Path]::GetTempFileName()
  try {
    Write-Utf8File $file $Body
    Invoke-AzCli -Step $Step -Arguments @('rest', '--method', $Method, '--url', $Url, '--headers', 'Content-Type=application/json', '--body', "@$file", '--output', 'none', '--only-show-errors')
  } finally {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue -WhatIf:$false
  }
}

function ConvertTo-JsonBody($Object) { $Object | ConvertTo-Json -Depth 100 -Compress }

function Remove-Properties($Object, [string[]]$Names) {
  foreach ($n in $Names) {
    if ($Object.PSObject.Properties[$n]) { $Object.PSObject.Properties.Remove($n) }
  }
}

function Get-DcrPutObject([string]$DcrText) {
  # The DCR as read, minus server-set properties: the body a PUT sends back.
  $dcr = $DcrText | ConvertFrom-Json
  Remove-Properties $dcr $DcrReadOnlyTop
  if ($dcr.PSObject.Properties['properties']) { Remove-Properties $dcr.properties $DcrReadOnlyProperties }
  return $dcr
}

function Get-StreamColumns($Dcr) {
  $streams = $Dcr.properties.streamDeclarations
  if (-not $streams -or -not $streams.PSObject.Properties[$StreamName]) {
    throw "The DCR has no '$StreamName' stream declaration. Check -DcrResourceId: it must be the Enhanced Inventory DCR."
  }
  return @($streams.$StreamName.columns)
}

function Get-MissingColumns([object[]]$Existing, [string]$Where) {
  # Columns to add. Throws when a column exists with a different type, because a re-run can't fix that.
  $byName = @{}
  foreach ($c in $Existing) { $byName[[string]$c.name] = [string]$c.type }
  $missing = @()
  foreach ($col in $AppUsageColumns) {
    if ($byName.ContainsKey($col.name)) {
      if ($byName[$col.name] -ne $col.type) {
        throw "$Where already has column '$($col.name)' with type '$($byName[$col.name])', but it must be '$($col.type)'. Fix that column first (a guid _g column must be string). Nothing was changed."
      }
    } else {
      $missing += $col
    }
  }
  return ,$missing
}

function Get-SortedCopy($Value) {
  # Copy of parsed JSON with object keys sorted, so two bodies compare equal whatever their key order.
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
  if ($Value -is [System.Collections.IDictionary]) {
    $copy = [ordered]@{}
    foreach ($k in @($Value.Keys | Sort-Object { [string]$_ } -CaseSensitive)) { $copy[[string]$k] = Get-SortedCopy $Value[$k] }
    return $copy
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    return ,@(foreach ($item in $Value) { ,(Get-SortedCopy $item) })
  }
  $copy = [ordered]@{}
  foreach ($p in @($Value.PSObject.Properties | Sort-Object Name -CaseSensitive)) { $copy[$p.Name] = Get-SortedCopy $p.Value }
  return $copy
}

function ConvertTo-CanonicalJson($Value) { ConvertTo-Json -InputObject (Get-SortedCopy $Value) -Depth 100 -Compress }

function Get-NormalizedDcr([string]$DcrText) {
  # Comparable form of a DCR: server-set properties removed, keys sorted.
  return ConvertTo-CanonicalJson (Get-DcrPutObject $DcrText)
}

function Save-Backup([string]$Kind, [string]$Text, [string]$Stamp) {
  if (-not (Test-Path -LiteralPath $BackupDirectory)) { New-Item -ItemType Directory -Path $BackupDirectory -Force -WhatIf:$false | Out-Null }
  $path = Join-Path $BackupDirectory "backup-$Stamp-$Kind.json"
  Write-Utf8File $path $Text
  Write-Host "Backed up the $Kind to $path"
  return $path
}

function Write-WaitNotice {
  Write-Host ''
  Write-Host 'IMPORTANT: Wait 30 minutes before you turn metering on.' -ForegroundColor Yellow
  Write-Host 'A DCR change takes about 30 minutes to reach every ingestion instance. Until then, uploads still succeed,'
  Write-Host 'but rows can lose the new columns without any error. A test row that keeps the new columns doesn''t prove'
  Write-Host 'that every upload will, so wait the full 30 minutes.'
}

# --------------------------------------------------
# Main
# --------------------------------------------------

$tableUrl = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/tables/$($TableName)?api-version=$TableApiVersion"
$workspaceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"
$dcrUrl = "$($DcrResourceId)?api-version=$DcrApiVersion"
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')

Invoke-AzCli -Step 'Azure CLI sign-in check (az account show)' -Arguments @('account', 'show', '--output', 'none')

if ($RollbackFrom) {
  # ---------------- Rollback: PUT a saved DCR backup ----------------
  $backupText = Read-Utf8File $RollbackFrom
  $backup = $backupText | ConvertFrom-Json
  if (-not $backup.PSObject.Properties['type'] -or $backup.type -ne 'Microsoft.Insights/dataCollectionRules') {
    throw "'$RollbackFrom' is not a DCR backup (expected type Microsoft.Insights/dataCollectionRules). Nothing was changed."
  }
  if (-not $backup.PSObject.Properties['id'] -or $backup.id -ne $DcrResourceId) {
    throw "'$RollbackFrom' is a backup of '$($backup.id)', not of '$DcrResourceId'. Nothing was changed."
  }

  Write-Warning 'Roll back the inventory script first (turn metering off, or redeploy the previous version), and the DCR second. An old DCR drops the run columns, so split rows sent to it break inventory for that device.'

  $currentText = Get-ArmText 'DCR read' $dcrUrl
  $putBody = ConvertTo-JsonBody (Get-DcrPutObject $backupText)
  $expected = Get-NormalizedDcr $backupText
  if ((Get-NormalizedDcr $currentText) -ceq $expected) {
    Write-Host "The DCR already matches '$RollbackFrom'. Nothing to roll back."
    return
  }
  if (-not $WhatIfPreference) { [void](Save-Backup 'dcr' $currentText $stamp) }

  if ($PSCmdlet.ShouldProcess($DcrResourceId, "Replace the DCR with the backup in '$RollbackFrom'")) {
    Send-ArmBody 'DCR rollback (PUT)' 'put' $dcrUrl $putBody
    $afterText = Get-ArmText 'DCR read after rollback' $dcrUrl
    if ((Get-NormalizedDcr $afterText) -cne $expected) {
      throw "The DCR was updated, but it doesn't match the backup. Compare it with '$RollbackFrom'."
    }
    Write-Host "Rolled back the DCR to '$RollbackFrom'. The table columns stay in place; the previous inventory script ignores them."
    Write-Host 'A DCR change takes about 30 minutes to reach every ingestion instance.'
  }
  return
}

# ---------------- Update ----------------

# 1. Read the DCR, check that it writes to this table and workspace, then read the table. Back up both.
$dcrText = Get-ArmText 'DCR read' $dcrUrl
$dcr     = $dcrText | ConvertFrom-Json

# The DCR must send the App Inventory stream to this table and workspace, or the table and the DCR won't match.
$flow = @($dcr.properties.dataFlows | Where-Object { @($_.streams) -contains $StreamName })
if (-not $flow) { throw "The DCR has no data flow for '$StreamName'. Check -DcrResourceId. Nothing was changed." }
$outputStream = if ($flow[0].PSObject.Properties['outputStream'] -and $flow[0].outputStream) { [string]$flow[0].outputStream } else { $StreamName }
if ($outputStream -ne "Custom-$TableName") {
  throw "The DCR writes '$StreamName' to '$outputStream', not to table '$TableName'. Check -DcrResourceId and -TableName. Nothing was changed."
}
$laDestinations = @()
if ($dcr.properties.destinations.PSObject.Properties['logAnalytics']) { $laDestinations = @($dcr.properties.destinations.logAnalytics) }
$targets = @($laDestinations | Where-Object { @($flow[0].destinations) -contains $_.name } | ForEach-Object { [string]$_.workspaceResourceId })
if (-not ($targets | Where-Object { $_ -eq $workspaceId })) {
  throw "The DCR sends '$StreamName' to '$($targets -join ', ')', not to workspace '$WorkspaceName' in resource group '$ResourceGroupName'. Check the parameters. Nothing was changed."
}

$tableText = Get-ArmText 'Table read' $tableUrl
$table     = $tableText | ConvertFrom-Json

$tableMissing  = Get-MissingColumns @($table.properties.schema.columns) "Table $TableName"
$streamMissing = Get-MissingColumns (Get-StreamColumns $dcr) "DCR stream $StreamName"

if (-not $WhatIfPreference) {
  [void](Save-Backup 'table' $tableText $stamp)
  $dcrBackup = Save-Backup 'dcr' $dcrText $stamp
}

if (-not $tableMissing.Count -and -not $streamMissing.Count) {
  Write-Host "Nothing to add: $TableName and the $StreamName stream already have all $($AppUsageColumns.Count) App Usage columns."
  Write-Host 'If the DCR was changed in the last 30 minutes, wait until 30 minutes have passed before you turn metering on.'
  return
}

if ($WhatIfPreference) {
  Write-Host "What if: would add $($tableMissing.Count) columns to table $TableName$(if ($tableMissing.Count) { ': ' + (($tableMissing | ForEach-Object { $_.name }) -join ', ') })"
  Write-Host "What if: would add $($streamMissing.Count) columns to DCR stream $StreamName$(if ($streamMissing.Count) { ': ' + (($streamMissing | ForEach-Object { $_.name }) -join ', ') })"
  Write-Host 'What if: nothing else in the DCR would change. No backups were written and nothing was changed.'
  return
}

# 2. Table first: additive, and harmless on its own.
if ($tableMissing.Count) {
  $columns = @()
  foreach ($c in @($table.properties.schema.columns)) {
    Remove-Properties $c $TableColumnReadOnly
    $columns += $c
  }
  $columns += $tableMissing
  $tableBody = ConvertTo-JsonBody @{ properties = @{ schema = @{ name = $TableName; columns = $columns } } }
  if ($PSCmdlet.ShouldProcess("$WorkspaceName/$TableName", "Add $($tableMissing.Count) columns")) {
    Send-ArmBody 'Table update (PATCH)' 'patch' $tableUrl $tableBody
    $deadline = (Get-Date).AddSeconds($TableWaitSeconds)
    while ($true) {
      $now = (Get-ArmText 'Table read after update' $tableUrl) | ConvertFrom-Json
      $stillMissing = Get-MissingColumns @($now.properties.schema.columns) "Table $TableName"
      if (-not $stillMissing.Count -and $now.properties.provisioningState -eq 'Succeeded') { break }
      if ((Get-Date) -gt $deadline) {
        throw "The table update was accepted, but after $TableWaitSeconds seconds the table still lacks: $(($stillMissing | ForEach-Object { $_.name }) -join ', '). The DCR wasn't changed. Run the script again later."
      }
      Start-Sleep -Seconds $TablePollSeconds
    }
    Write-Host "Table: added $($tableMissing.Count) columns to $TableName."
  }
} else {
  Write-Host "Table: nothing to add; $TableName already has the App Usage columns."
}

# 3. DCR: append the missing columns to the App Inventory stream; send everything else back as read.
if ($streamMissing.Count) {
  $putObject = Get-DcrPutObject $dcrText
  $stream = $putObject.properties.streamDeclarations.$StreamName
  $stream.columns = @($stream.columns) + @($streamMissing | ForEach-Object { [pscustomobject]$_ })
  $putBody = ConvertTo-JsonBody $putObject
  if ($PSCmdlet.ShouldProcess($DcrResourceId, "Add $($streamMissing.Count) columns to the $StreamName stream")) {
    Send-ArmBody 'DCR update (PUT)' 'put' $dcrUrl $putBody

    # 4. Verify: the DCR now reads back as the DCR read in step 1 plus the appended columns, nothing else.
    $afterText = Get-ArmText 'DCR read after update' $dcrUrl
    if ((Get-NormalizedDcr $afterText) -cne (ConvertTo-CanonicalJson ($putBody | ConvertFrom-Json))) {
      throw "The DCR update was accepted, but the DCR doesn't read back as the original plus the new columns. Compare it with '$dcrBackup', and restore it with -RollbackFrom if needed."
    }
    Write-Host "DCR: added $($streamMissing.Count) columns to the $StreamName stream. Nothing else in the DCR changed."
    Write-WaitNotice
  }
} else {
  Write-Host "DCR: nothing to add; the $StreamName stream already has the App Usage columns."
  Write-Host 'If the DCR was changed in the last 30 minutes, wait until 30 minutes have passed before you turn metering on.'
}
