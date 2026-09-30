// AVD desktop application group
//
// One per host pool. A Desktop group publishes the full desktop; RemoteApp
// groups publish individual applications and are not deployed by this
// template.
//
// This module also assigns the Desktop Virtualization User role to the AVD
// users group. Without that assignment the desktop exists but no one can
// see it in the client - which was a gap in v1 that had to be fixed by hand
// after every deployment.

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

param location string
param applicationGroupName string
param friendlyName string

@description('Resource ID of the host pool this group belongs to.')
param hostPoolId string

@description('Entra ID object ID of the group that should see and launch this desktop. Empty string skips the assignment, in which case you must assign users manually before anyone can connect.')
param avdUsersGroupObjectId string = ''

@description('Log Analytics workspace resource ID for diagnostics. Empty string skips the diagnostic setting.')
param logAnalyticsWorkspaceId string = ''

// Desktop Virtualization User - grants
// Microsoft.DesktopVirtualization/applicationGroups/useApplications/action,
// assigned at application group scope.
var desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: applicationGroupName
  tags: tags
  location: location
  properties: {
    friendlyName: friendlyName
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPoolId
  }
}

// Deterministic name, so redeploying updates this assignment rather than
// creating a duplicate.
resource userAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdUsersGroupObjectId)) {
  scope: appGroup
  name: guid(appGroup.id, avdUsersGroupObjectId, desktopVirtualizationUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', desktopVirtualizationUserRoleId)
    principalId: avdUsersGroupObjectId
    principalType: 'Group'
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  scope: appGroup
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

output applicationGroupId string = appGroup.id
output applicationGroupName string = appGroup.name
