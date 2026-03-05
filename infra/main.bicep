targetScope = 'resourceGroup'

// ==================================================
// Parameters
// ==================================================

@description('Choose whether to create a new Log Analytics workspace or use an existing one.')
@allowed([
  'CreateNew'
  'UseExisting'
])
param workspaceMode string = 'CreateNew'

@description('Deployment location. Only used when creating a new workspace. When using an existing workspace, the location is automatically derived from the workspace.')
param location string = resourceGroup().location

// ---------------------------
// New workspace (CreateNew)
// ---------------------------

@description('Name of the new Log Analytics workspace. Only used when WorkspaceMode is set to CreateNew. Ignored when using an existing workspace.')
param newWorkspaceName string = 'law-PowerStacksEnhancedInventory'

// ---------------------------
// Existing workspace (UseExisting)
// ---------------------------

@description('Subscription ID of the existing Log Analytics workspace. Required only when WorkspaceMode is set to UseExisting. Leave blank when creating a new workspace.')
param existingWorkspaceSubscriptionId string = subscription().subscriptionId

@description('Resource group name of the existing Log Analytics workspace. Required only when WorkspaceMode is set to UseExisting.')
param existingWorkspaceResourceGroup string = ''

@description('Name of the existing Log Analytics workspace. Required only when WorkspaceMode is set to UseExisting.')
param existingWorkspaceName string = ''

// ---------------------------
// DCE / DCR
// ---------------------------

@description('Name of the Data Collection Endpoint (DCE) to create.')
param dceName string = 'dce-PowerStacksInventory'

@description('Name of the Data Collection Rule (DCR) to create.')
param dcrName string = 'dcr-PowerStacksInventory'

// ---------------------------
// Optional RBAC
// ---------------------------

@description('Optional. Object ID of the Enterprise Application (service principal). NOT the Application (Client) ID. Used to assign Monitoring Metrics Publisher on the DCR. If left blank, permissions must be assigned manually after deployment.')
param enterpriseAppObjectId string = ''

// ==================================================
// Table names
// ==================================================

var deviceTableName = 'PowerStacksDeviceInventory_CL'
var appTableName    = 'PowerStacksAppInventory_CL'
var driverTableName = 'PowerStacksDriverInventory_CL'

// ==================================================
// Schemas (columns defined once, reused)
// ==================================================

var deviceColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'ComputerName_s', type: 'string' }
  { name: 'ManagedDeviceID_g', type: 'string' }
  { name: 'Microsoft365_b', type: 'boolean' }
  { name: 'Warranty_b', type: 'boolean' }
  { name: 'DeviceDetails1_s', type: 'string' }
  { name: 'DeviceDetails2_s', type: 'string' }
  { name: 'DeviceDetails3_s', type: 'string' }
  { name: 'DeviceDetails4_s', type: 'string' }
  { name: 'DeviceDetails5_s', type: 'string' }
  { name: 'DeviceDetails6_s', type: 'string' }
  { name: 'DeviceDetails7_s', type: 'string' }
  { name: 'DeviceDetails8_s', type: 'string' }
  { name: 'DeviceDetails9_s', type: 'string' }
  { name: 'DeviceDetails10_s', type: 'string' }
]

var appColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'ComputerName_s', type: 'string' }
  { name: 'ManagedDeviceID_g', type: 'string' }
  { name: 'InstalledApps1_s', type: 'string' }
  { name: 'InstalledApps2_s', type: 'string' }
  { name: 'InstalledApps3_s', type: 'string' }
  { name: 'InstalledApps4_s', type: 'string' }
  { name: 'InstalledApps5_s', type: 'string' }
  { name: 'InstalledApps6_s', type: 'string' }
  { name: 'InstalledApps7_s', type: 'string' }
  { name: 'InstalledApps8_s', type: 'string' }
  { name: 'InstalledApps9_s', type: 'string' }
  { name: 'InstalledApps10_s', type: 'string' }
]

var driverColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'ComputerName_s', type: 'string' }
  { name: 'ManagedDeviceID_g', type: 'string' }
  { name: 'ListedDrivers1_s', type: 'string' }
  { name: 'ListedDrivers2_s', type: 'string' }
  { name: 'ListedDrivers3_s', type: 'string' }
  { name: 'ListedDrivers4_s', type: 'string' }
  { name: 'ListedDrivers5_s', type: 'string' }
  { name: 'ListedDrivers6_s', type: 'string' }
  { name: 'ListedDrivers7_s', type: 'string' }
  { name: 'ListedDrivers8_s', type: 'string' }
  { name: 'ListedDrivers9_s', type: 'string' }
  { name: 'ListedDrivers10_s', type: 'string' }
]

// ==================================================
// Workspace (new or existing)
// ==================================================

resource lawNew 'Microsoft.OperationalInsights/workspaces@2022-10-01' = if (workspaceMode == 'CreateNew') {
  name: newWorkspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource existingRg 'Microsoft.Resources/resourceGroups@2021-04-01' existing = if (workspaceMode == 'UseExisting') {
  name: existingWorkspaceResourceGroup
  scope: subscription(existingWorkspaceSubscriptionId)
}

resource lawExisting 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = if (workspaceMode == 'UseExisting') {
  name: existingWorkspaceName
  scope: existingRg
}

var workspaceResourceId    = workspaceMode == 'CreateNew' ? lawNew.id : lawExisting.id
var workspaceNameEffective = workspaceMode == 'CreateNew' ? lawNew.name : lawExisting.name
var effectiveLocation      = workspaceMode == 'CreateNew' ? location : lawExisting!.location

// ==================================================
// DCE (CreateNew only – UseExisting creates its own DCE in the workspace RG
// so that DCE and DCR are co-located in the same region)
// ==================================================

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2024-03-11' = if (workspaceMode == 'CreateNew') {
  name: dceName
  location: location
  properties: {
    description: 'DCE for PowerStacks Enhanced Inventory ingestion'
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ==================================================
// CreateNew path: Tables + DCR in the same RG
// ==================================================

resource deviceTableNew 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = if (workspaceMode == 'CreateNew') {
  parent: lawNew
  name: deviceTableName
  properties: {
    plan: 'Analytics'
    schema: {
      name: deviceTableName
      columns: deviceColumns
    }
  }
}

resource appTableNew 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = if (workspaceMode == 'CreateNew') {
  parent: lawNew
  name: appTableName
  properties: {
    plan: 'Analytics'
    schema: {
      name: appTableName
      columns: appColumns
    }
  }
}

resource driverTableNew 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = if (workspaceMode == 'CreateNew') {
  parent: lawNew
  name: driverTableName
  properties: {
    plan: 'Analytics'
    schema: {
      name: driverTableName
      columns: driverColumns
    }
  }
}

resource dcrNew 'Microsoft.Insights/dataCollectionRules@2024-03-11' = if (workspaceMode == 'CreateNew') {
  name: dcrName
  location: location
  dependsOn: [
    deviceTableNew
    appTableNew
    driverTableNew
  ]
  properties: {
    description: 'PowerStacks Enhanced Inventory ingestion via Log Ingestion API'
    dataCollectionEndpointId: dce!.id

    destinations: {
      logAnalytics: [
        {
          name: 'la-destination'
          workspaceResourceId: workspaceResourceId
        }
      ]
    }

    streamDeclarations: {
      'Custom-${deviceTableName}': { columns: deviceColumns }
      'Custom-${appTableName}':    { columns: appColumns }
      'Custom-${driverTableName}': { columns: driverColumns }
    }

    dataFlows: [
      {
        streams: [ 'Custom-${deviceTableName}' ]
        destinations: [ 'la-destination' ]
        transformKql: 'source | extend TimeGenerated = now()'
        outputStream: 'Custom-${deviceTableName}'
      }
      {
        streams: [ 'Custom-${appTableName}' ]
        destinations: [ 'la-destination' ]
        transformKql: 'source | extend TimeGenerated = now()'
        outputStream: 'Custom-${appTableName}'
      }
      {
        streams: [ 'Custom-${driverTableName}' ]
        destinations: [ 'la-destination' ]
        transformKql: 'source | extend TimeGenerated = now()'
        outputStream: 'Custom-${driverTableName}'
      }
    ]
  }
}

// Optional RBAC for CreateNew DCR
var monitoringMetricsPublisherRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb'
)

resource dcrRoleNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (workspaceMode == 'CreateNew' && !empty(enterpriseAppObjectId)) {
  name: guid(dcrNew.id, enterpriseAppObjectId, monitoringMetricsPublisherRoleDefinitionId)
  scope: dcrNew
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleDefinitionId
    principalId: enterpriseAppObjectId
    principalType: 'ServicePrincipal'
  }
}

// ==================================================
// UseExisting path: Tables + DCR created in the workspace RG via module
// ==================================================

module existingWorkspaceTablesAndDcr 'modules/workspaceTablesAndDcr.bicep' = if (workspaceMode == 'UseExisting') {
  name: 'existingWorkspaceTablesAndDcr'
  scope: existingRg
  params: {
    workspaceName: existingWorkspaceName

    dcrName: dcrName
    dceName: dceName
    location: effectiveLocation

    deviceTableName: deviceTableName
    appTableName: appTableName
    driverTableName: driverTableName

    deviceColumns: deviceColumns
    appColumns: appColumns
    driverColumns: driverColumns

    enterpriseAppObjectId: enterpriseAppObjectId
  }
}

// ==================================================
// Outputs
// ==================================================

var dcrImmutableIdNew = workspaceMode == 'CreateNew' ? dcrNew!.properties.immutableId : ''
var dcrImmutableIdExisting = workspaceMode == 'UseExisting' ? existingWorkspaceTablesAndDcr!.outputs.DcrImmutableId : ''


output DceURI string = workspaceMode == 'CreateNew'
  ? dce!.properties.logsIngestion.endpoint
  : existingWorkspaceTablesAndDcr!.outputs.DceURI

output DcrImmutableId string = workspaceMode == 'CreateNew'
  ? dcrImmutableIdNew
  : dcrImmutableIdExisting

output WorkspaceResourceId string = workspaceResourceId
output WorkspaceName string = workspaceNameEffective

output RoleAssignmentSkipped bool = empty(enterpriseAppObjectId)
