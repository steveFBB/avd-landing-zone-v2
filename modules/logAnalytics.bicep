// Log Analytics workspace
//
// One workspace, receiving infrastructure diagnostics from the VNets and
// the storage account.
//
// This is infrastructure logging only. AVD Insights needs diagnostics from
// the host pool, workspace and application groups plus agents on the
// session hosts, none of which this template configures.

param location string
param workspaceName string

@description('Data retention in days. Azure default is 30; valid range is 30-730.')
@minValue(30)
@maxValue(730)
param retentionInDays int

@allowed([
  'PerGB2018'
  'CapacityReservation'
  'Free'
  'Standalone'
  'PerNode'
  'Standard'
  'Premium'
])
@description('PerGB2018 is the current pay-as-you-go SKU. The others exist for legacy workspaces.')
param sku string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    features: {
      // Permissions on each resource control who can read its logs, rather
      // than requiring separate workspace-level RBAC.
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
