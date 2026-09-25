// Diagnostic settings for a VNet
//
// Called once per VNet — the hub and each spoke. Scoped to whichever
// resource group the VNet lives in.
//
// categoryGroup 'allLogs' rather than naming individual categories: it
// picks up new log categories automatically when Azure adds them, instead
// of silently missing them until someone updates the template.

param vnetName string
param workspaceId string
param diagnosticSettingName string = 'diag-to-law'

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: vnetName
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: vnet
  name: diagnosticSettingName
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}
