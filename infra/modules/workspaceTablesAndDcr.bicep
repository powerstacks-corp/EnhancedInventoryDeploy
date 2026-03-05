targetScope = 'resourceGroup'

param workspaceName string
param dcrName string
param location string
param dceResourceId string

param deviceTableName string
param appTableName string
param driverTableName string

param deviceColumns array
param appColumns array
param driverColumns array

@description('Optional. Object ID of the Enterprise Application (service principal). NOT the Application (Client) ID. If provided, the module assigns DCR permissions automatically.')
param enterpriseAppObjectId string = ''

resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

resource deviceTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: deviceTableName
  properties: {
    plan: 'Analytics'
    schema: {
      name: deviceTableName
      columns: deviceColumns
    }
  }
}

resource appTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: appTableName
  properties: {
    plan: 'Analytics'
    schema: {
      name: appTableName
      columns: appColumns
    }
  }
}

resource driverTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: driverTableName
  properties: {
    plan: 'Analytics'
    schema: {
      name: driverTableName
      columns: driverColumns
    }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: dcrName
  location: location
  dependsOn: [
    deviceTable
    appTable
    driverTable
  ]
  properties: {
    description: 'PowerStacks Enhanced Inventory ingestion via Log Ingestion API'
    dataCollectionEndpointId: dceResourceId

    destinations: {
      logAnalytics: [
        {
          name: 'la-destination'
          workspaceResourceId: law.id
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

var monitoringMetricsPublisherRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb'
)

resource dcrRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(enterpriseAppObjectId)) {
  name: guid(dcr.id, enterpriseAppObjectId, monitoringMetricsPublisherRoleDefinitionId)
  scope: dcr
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleDefinitionId
    principalId: enterpriseAppObjectId
    principalType: 'ServicePrincipal'
  }
}

output DcrImmutableId string = dcr.properties.immutableId
