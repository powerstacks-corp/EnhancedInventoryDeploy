#Requires -Version 5.1
# Offline tests for Update-PowerStacksAppInventorySchema.ps1. A fake 'az' function stands in for
# Azure Resource Manager: it serves the fixture JSON, records every write, and can fail a call.
# Run: Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path postdeploy\tests -Output Detailed

BeforeAll {
  $script:Updater  = Join-Path $PSScriptRoot '..\Update-PowerStacksAppInventorySchema.ps1'
  $script:Fixtures = Join-Path $PSScriptRoot 'fixtures'
  $script:RepoRoot = Join-Path $PSScriptRoot '..\..'
  $script:Sub   = '00000000-0000-0000-0000-000000000000'
  $script:DcrId = "/subscriptions/$Sub/resourceGroups/rg-inventory/providers/Microsoft.Insights/dataCollectionRules/dcr-PowerStacksInventory"
  $script:Utf8  = New-Object System.Text.UTF8Encoding($false)

  # The 22 App Usage columns, in order (spec "Device-Level Columns", D43, D44).
  $script:NewColumns = @(
    @{ name = 'AppUsageEnabled_b'; type = 'boolean' }, @{ name = 'WatchingSince_t'; type = 'datetime' },
    @{ name = 'AppUsageScriptVersion_s'; type = 'string' }, @{ name = 'MappingsVersion_s'; type = 'string' },
    @{ name = 'CustomerMappingsHash_s'; type = 'string' }, @{ name = 'UnmatchedExeCount_d'; type = 'real' },
    @{ name = 'ProfilesFound_d'; type = 'real' }, @{ name = 'ProfilesRead_d'; type = 'real' },
    @{ name = 'AppUsageCollectionStatus_s'; type = 'string' }
  )
  foreach ($i in 1..10) { $script:NewColumns += @{ name = "ExeUsage$($i)_s"; type = 'string' } }
  $script:NewColumns += @{ name = 'RunId_g'; type = 'string' }, @{ name = 'RowIndex_d'; type = 'real' }, @{ name = 'RowCount_d'; type = 'real' }

  function script:Read-Fixture([string]$Name) { [IO.File]::ReadAllText((Join-Path $script:Fixtures $Name), [Text.Encoding]::UTF8) }

  # Deep comparison of parsed JSON, independent of the updater's code. Returns the differing paths.
  function script:Compare-Json($A, $B, [string]$Path = '$') {
    if ($null -eq $A -or $null -eq $B) { if (-not ($null -eq $A -and $null -eq $B)) { return "$Path : null vs value" } ; return }
    if ($A -is [string] -or $A -is [ValueType]) {
      if ($A.GetType() -ne $B.GetType() -or -not $A.Equals($B)) { return "$Path : '$A' vs '$B'" }
      return
    }
    if ($A -is [Array]) {
      if ($B -isnot [Array]) { return "$Path : array vs non-array" }
      if ($A.Count -ne $B.Count) { return "$Path : $($A.Count) items vs $($B.Count)" }
      for ($i = 0; $i -lt $A.Count; $i++) { Compare-Json $A[$i] $B[$i] "$Path[$i]" }
      return
    }
    $an = @($A.PSObject.Properties | ForEach-Object Name); $bn = @($B.PSObject.Properties | ForEach-Object Name)
    foreach ($n in $an) { if ($bn -cnotcontains $n) { "$Path.$n : missing on the right" } }
    foreach ($n in $bn) { if ($an -cnotcontains $n) { "$Path.$n : missing on the left" } }
    foreach ($n in $an) { if ($bn -ccontains $n) { Compare-Json $A.$n $B.$n "$Path.$n" } }
  }

  function script:Remove-ReadOnly($Dcr) {
    foreach ($p in 'id', 'name', 'type', 'etag', 'systemData') { $Dcr.PSObject.Properties.Remove($p) }
    foreach ($p in 'immutableId', 'provisioningState', 'metadata', 'endpoints') { $Dcr.properties.PSObject.Properties.Remove($p) }
    $Dcr
  }

  function script:Get-ExpectedPut([string]$DcrText) {
    # The fixture as read, minus server-set properties, plus the 22 columns appended to the App Inventory stream.
    $d = Remove-ReadOnly ($DcrText | ConvertFrom-Json)
    $s = $d.properties.streamDeclarations.'Custom-PowerStacksAppInventory_CL'
    $s.columns = @($s.columns) + @($script:NewColumns | ForEach-Object { [pscustomobject]@{ name = $_.name; type = $_.type } })
    $d
  }

  function script:New-FakeArm([string]$TableFixture, [string]$DcrFixture) {
    # The fixtures are ASCII and escape their non-ASCII characters; serve those as real UTF-8, as Azure does.
    $served = (Read-Fixture $DcrFixture).Replace('é', [string][char]0xE9)
    $global:FakeArm = @{
      table  = Read-Fixture $TableFixture
      dcr    = $served
      ServedDcr = $served
      Calls  = New-Object System.Collections.Generic.List[string]
      Bodies = New-Object System.Collections.Generic.List[object]
      Fail   = @()
    }
  }

  function script:Invoke-Updater([hashtable]$Extra = @{}) {
    $p = @{ SubscriptionId = $script:Sub; ResourceGroupName = 'rg-inventory'; WorkspaceName = 'law-inventory'; DcrResourceId = $script:DcrId; BackupDirectory = $script:BackupDir }
    foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
    (& $script:Updater @p 6>&1 3>&1 | Out-String)
  }

  function script:Get-Writes { @($global:FakeArm.Calls | Where-Object { $_ -notlike 'get *' }) }

  # Fake az: 'account show' and 'rest' GET/PATCH/PUT against the in-memory table and DCR.
  function global:az {
    $a = @($args)
    $arm = $global:FakeArm
    if ($a[0] -eq 'account') {
      Write-Error 'WARNING: a simulated az warning on stderr'   # stderr alone must not count as failure
      $global:LASTEXITCODE = 0
      return
    }
    $method = $a[[Array]::IndexOf($a, '--method') + 1]
    $url    = $a[[Array]::IndexOf($a, '--url') + 1]
    $kind   = if ($url -match '/tables/PowerStacksAppInventory_CL\?') { 'table' } elseif ($url -match '/dataCollectionRules/dcr-PowerStacksInventory\?') { 'dcr' } else { 'unknown' }
    $arm.Calls.Add("$method $kind")
    if ($kind -eq 'unknown') { Write-Output "ERROR: (ResourceNotFound) $url"; $global:LASTEXITCODE = 3; return }
    if ($arm.Fail -contains "$method $kind") {
      Write-Output "ERROR: (InvalidPayload) simulated failure of $method $kind"
      $global:LASTEXITCODE = 1
      return
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if ($method -eq 'get') {
      [IO.File]::WriteAllText($a[[Array]::IndexOf($a, '--output-file') + 1], $arm[$kind], $utf8)
    } else {
      $bodyText = [IO.File]::ReadAllText($a[[Array]::IndexOf($a, '--body') + 1].Substring(1), [Text.Encoding]::UTF8)
      $arm.Bodies.Add([pscustomobject]@{ Call = "$method $kind"; Text = $bodyText })
      $old = $arm[$kind] | ConvertFrom-Json
      $body = $bodyText | ConvertFrom-Json
      if ($kind -eq 'table') {
        # PATCH: the column list is replaced; the server adds its read-only column properties back.
        $old.properties.schema.columns = @($body.properties.schema.columns | ForEach-Object {
          [pscustomobject]@{ isDefaultDisplay = $false; isHidden = $false; name = $_.name; type = $_.type } })
        $arm.table = $old | ConvertTo-Json -Depth 100
      } else {
        # PUT: the body replaces the DCR; the server adds its read-only properties back.
        foreach ($p in 'id', 'name', 'type', 'systemData') { $body | Add-Member -NotePropertyName $p -NotePropertyValue $old.$p }
        $body | Add-Member -NotePropertyName etag -NotePropertyValue '"99999999-0000-0100-0000-000000000000"'
        foreach ($p in 'immutableId', 'provisioningState', 'metadata', 'endpoints') {
          if ($old.properties.PSObject.Properties[$p]) { $body.properties | Add-Member -NotePropertyName $p -NotePropertyValue $old.properties.$p }
        }
        $arm.dcr = $body | ConvertTo-Json -Depth 100
      }
    }
    $global:LASTEXITCODE = 0
  }
}

AfterAll {
  Remove-Item Function:\global:az -ErrorAction SilentlyContinue
  Remove-Variable FakeArm -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Update-PowerStacksAppInventorySchema' {
  BeforeEach {
    $script:BackupDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:BackupDir | Out-Null
  }

  Context 'Preservation' {
    It 'PUTs the <Dcr> DCR exactly as read except for the 22 appended columns' -ForEach @(
      @{ Dcr = 'rich-dcr-before.json' }   # three streams, custom transforms, two destinations, DCE, user-assigned identity, tags
      @{ Dcr = 'lab-dcr-before.json' }    # the lab DCR before the update, sanitized
    ) {
      New-FakeArm 'lab-table-before.json' $Dcr
      $out = Invoke-Updater
      Get-Writes | Should -Be @('patch table', 'put dcr')

      $put = $global:FakeArm.Bodies | Where-Object Call -eq 'put dcr'
      $diff = @(Compare-Json (Get-ExpectedPut (Read-Fixture $Dcr)) ($put.Text | ConvertFrom-Json))
      $diff | Should -BeNullOrEmpty

      $out | Should -Match 'DCR: added 22 columns'
      $out | Should -Match 'Wait 30 minutes before you turn metering on'
    }

    It 'sends the table its existing columns plus the 22, without the read-only column properties' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      Invoke-Updater | Out-Null
      $patch = ($global:FakeArm.Bodies | Where-Object Call -eq 'patch table').Text | ConvertFrom-Json
      $existing = @((Read-Fixture 'lab-table-before.json' | ConvertFrom-Json).properties.schema.columns | ForEach-Object { [pscustomobject]@{ name = $_.name; type = $_.type } })
      $expected = [pscustomobject]@{ properties = [pscustomobject]@{ schema = [pscustomobject]@{
        name = 'PowerStacksAppInventory_CL'
        columns = $existing + @($script:NewColumns | ForEach-Object { [pscustomobject]@{ name = $_.name; type = $_.type } }) } } }
      @(Compare-Json $expected $patch) | Should -BeNullOrEmpty
    }

    It 'saves the table and DCR exactly as read, as time-stamped table and DCR backup files' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      Invoke-Updater | Out-Null
      $files = @(Get-ChildItem $script:BackupDir | ForEach-Object Name | Sort-Object)
      $files.Count | Should -Be 2
      $files[0] | Should -Match '^backup-\d{14}-dcr\.json$'
      $files[1] | Should -Match '^backup-\d{14}-table\.json$'
      [IO.File]::ReadAllText((Join-Path $script:BackupDir $files[0])) | Should -BeExactly $global:FakeArm.ServedDcr
      [IO.File]::ReadAllText((Join-Path $script:BackupDir $files[1])) | Should -BeExactly (Read-Fixture 'lab-table-before.json')
    }
  }

  Context 'Idempotence' {
    It 'a second run changes nothing and sends no PATCH or PUT, but still backs up what it read' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      Invoke-Updater | Out-Null
      $tableAfterFirst = $global:FakeArm.table; $dcrAfterFirst = $global:FakeArm.dcr
      $global:FakeArm.Calls.Clear()
      Remove-Item (Join-Path $script:BackupDir '*')

      $out = Invoke-Updater
      @(Get-ChildItem $script:BackupDir -Filter 'backup-*.json').Count | Should -Be 2
      Get-Writes | Should -BeNullOrEmpty
      $global:FakeArm.table | Should -BeExactly $tableAfterFirst
      $global:FakeArm.dcr | Should -BeExactly $dcrAfterFirst
      $out | Should -Match 'Nothing to add'
    }
  }

  Context 'Partial upgrade' {
    It 'fails loudly when the DCR PUT fails, and a re-run completes the DCR only' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      $global:FakeArm.Fail = @('put dcr')
      { Invoke-Updater } | Should -Throw '*DCR update (PUT) failed (az exit code 1)*simulated failure*'
      $global:FakeArm.dcr | Should -BeExactly $global:FakeArm.ServedDcr
      @(($global:FakeArm.table | ConvertFrom-Json).properties.schema.columns).Count | Should -Be (13 + 22)

      $global:FakeArm.Fail = @(); $global:FakeArm.Calls.Clear(); $global:FakeArm.Bodies.Clear()
      $out = Invoke-Updater
      Get-Writes | Should -Be @('put dcr')
      $out | Should -Match 'Table: nothing to add'
      @(Compare-Json (Get-ExpectedPut (Read-Fixture 'rich-dcr-before.json')) ($global:FakeArm.Bodies[0].Text | ConvertFrom-Json)) | Should -BeNullOrEmpty
    }

    It 'does not touch the DCR when the table PATCH fails' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      $global:FakeArm.Fail = @('patch table')
      { Invoke-Updater } | Should -Throw '*Table update (PATCH) failed*'
      Get-Writes | Should -Be @('patch table')
      $global:FakeArm.dcr | Should -BeExactly $global:FakeArm.ServedDcr
    }

    It 'fails loudly, before any write, when a read fails' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      $global:FakeArm.Fail = @('get dcr')
      { Invoke-Updater } | Should -Throw '*DCR read failed*'
      Get-Writes | Should -BeNullOrEmpty
      @(Get-ChildItem $script:BackupDir).Count | Should -Be 0
    }
  }

  Context 'Rollback' {
    It 'restores the backup body exactly, after backing up the current DCR' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      Invoke-Updater | Out-Null
      $backup = Get-ChildItem $script:BackupDir -Filter 'backup-*-dcr.json' | Select-Object -First 1
      $afterUpdate = $global:FakeArm.dcr
      $global:FakeArm.Calls.Clear(); $global:FakeArm.Bodies.Clear()
      Start-Sleep -Seconds 1   # new backup time stamp

      $out = Invoke-Updater @{ RollbackFrom = $backup.FullName }
      Get-Writes | Should -Be @('put dcr')
      $expected = Remove-ReadOnly (Read-Fixture 'rich-dcr-before.json' | ConvertFrom-Json)
      @(Compare-Json $expected ($global:FakeArm.Bodies[0].Text | ConvertFrom-Json)) | Should -BeNullOrEmpty
      @(Compare-Json $expected (Remove-ReadOnly ($global:FakeArm.dcr | ConvertFrom-Json))) | Should -BeNullOrEmpty
      $out | Should -Match 'Rolled back the DCR'
      $out | Should -Match 'table columns stay in place'

      $preRollback = Get-ChildItem $script:BackupDir -Filter 'backup-*-dcr.json' | Where-Object Name -ne $backup.Name
      @($preRollback).Count | Should -Be 1
      [IO.File]::ReadAllText($preRollback.FullName) | Should -BeExactly $afterUpdate
    }

    It 'refuses a backup of another resource, and changes nothing' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      $tableBackup = Join-Path $script:BackupDir 'backup-20260101000000-table.json'
      [IO.File]::WriteAllText($tableBackup, (Read-Fixture 'lab-table-before.json'), $script:Utf8)
      { Invoke-Updater @{ RollbackFrom = $tableBackup } } | Should -Throw '*is not a DCR backup*'

      $otherDcr = Join-Path $script:BackupDir 'backup-20260101000000-dcr.json'
      [IO.File]::WriteAllText($otherDcr, ((Read-Fixture 'rich-dcr-before.json') -replace 'dcr-PowerStacksInventory"', 'dcr-Other"'), $script:Utf8)
      { Invoke-Updater @{ RollbackFrom = $otherDcr } } | Should -Throw '*is a backup of*dcr-Other*'
      Get-Writes | Should -BeNullOrEmpty
    }

    It 'fails loudly when the rollback PUT fails' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      $file = Join-Path $script:BackupDir 'backup-20260101000000-dcr.json'
      [IO.File]::WriteAllText($file, (Read-Fixture 'lab-dcr-before.json'), $script:Utf8)
      $global:FakeArm.Fail = @('put dcr')
      { Invoke-Updater @{ RollbackFrom = $file } } | Should -Throw '*DCR rollback (PUT) failed*'
    }
  }

  Context 'Guards' {
    It '-WhatIf reports the columns and writes nothing, not even backups' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      $out = Invoke-Updater @{ WhatIf = $true }
      Get-Writes | Should -BeNullOrEmpty
      @(Get-ChildItem $script:BackupDir).Count | Should -Be 0
      $out | Should -Match 'would add 22 columns to table'
      $out | Should -Match 'would add 22 columns to DCR stream'
    }

    It 'refuses a column that exists with another type, such as a guid RunId_g' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      $t = $global:FakeArm.table | ConvertFrom-Json
      $t.properties.schema.columns = @($t.properties.schema.columns) + [pscustomobject]@{ name = 'RunId_g'; type = 'guid' }
      $global:FakeArm.table = $t | ConvertTo-Json -Depth 100
      { Invoke-Updater } | Should -Throw "*column 'RunId_g' with type 'guid', but it must be 'string'*"
      Get-Writes | Should -BeNullOrEmpty
    }

    It 'refuses a DCR that sends the App Inventory stream to another workspace' {
      New-FakeArm 'lab-table-before.json' 'rich-dcr-before.json'
      { Invoke-Updater @{ WorkspaceName = 'law-other' } } | Should -Throw '*not to workspace*law-other*'
      Get-Writes | Should -BeNullOrEmpty
    }
  }
}

Describe 'New deployments declare the same 22 columns' {
  It '<File> has the 22 columns after the 13 existing App Inventory columns' -ForEach @(
    @{ File = 'infra/main.json' }
    @{ File = 'infra/build/main.json' }
  ) {
    $template = [IO.File]::ReadAllText((Join-Path $script:RepoRoot $File)) | ConvertFrom-Json
    $cols = @($template.variables.appColumns)
    $cols.Count | Should -Be 35
    for ($i = 0; $i -lt 22; $i++) {
      "$($cols[13 + $i].name):$($cols[13 + $i].type)" | Should -BeExactly "$($script:NewColumns[$i].name):$($script:NewColumns[$i].type)"
    }
  }

  It 'New-PowerStacksInventoryTables.ps1 declares each of the 22 columns' {
    $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'postdeploy/New-PowerStacksInventoryTables.ps1'))
    foreach ($c in $script:NewColumns) {
      $text | Should -Match ("@\{\s*name\s*=\s*'" + [regex]::Escape($c.name) + "';\s*type\s*=\s*'" + $c.type + "'\s*\}")
    }
  }
}
