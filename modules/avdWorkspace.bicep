// AVD workspace
//
// One workspace for the whole deployment. This is what users subscribe to
// in the AVD client; every application group referenced here appears inside
// it as an available desktop.
//
// All host pools' application groups are referenced by this single
// workspace, which is why it is created after them.

param location string
param workspaceName string
param friendlyName string

@description('Resource IDs of the application groups to surface in this workspace.')
param applicationGroupReferences array

@description('Log Analytics workspace resource ID for diagnostics. Empty string skips the diagnostic setting.')
param logAnalyticsWorkspaceId string = ''

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' = {
  name: workspaceName
  location: location
  properties: {
    friendlyName: friendlyName
    applicationGroupReferences: applicationGroupReferences
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  scope: workspace
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name
