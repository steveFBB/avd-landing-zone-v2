// Azure RBAC on the FSLogix file share
//
// Grants two Entra ID groups access to the share:
//   users  -> Storage File Data SMB Share Contributor (read/write)
//   admins -> Storage File Data SMB Share Elevated Contributor
//             (read/write plus the ability to modify NTFS ACLs)
//
// Both group IDs are optional. An empty string skips that assignment, so
// the template still deploys before the customer has created the groups.
//
// This controls WHO can reach the share. It does not set the NTFS
// permissions on files and directories inside it — that is a separate,
// manual step from a client that has mounted the share.
//
// Role definition IDs are Microsoft's built-in ones and are stable.

param storageAccountName string
param fileShareName string

@description('Entra ID object ID of the AVD users group. Empty string skips the assignment.')
param avdUsersGroupObjectId string = ''

@description('Entra ID object ID of the AVD admins group. Empty string skips the assignment.')
param avdAdminsGroupObjectId string = ''

var smbShareContributorRoleId = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
var smbShareElevatedContributorRoleId = 'a7264617-510b-434b-a828-9731dc254ea7'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' existing = {
  parent: fileServices
  name: fileShareName
}

// guid() over the scope, principal and role makes these names deterministic,
// so redeploying updates the same assignment rather than creating another.
resource usersAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdUsersGroupObjectId)) {
  scope: fileShare
  name: guid(fileShare.id, avdUsersGroupObjectId, smbShareContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', smbShareContributorRoleId)
    principalId: avdUsersGroupObjectId
    principalType: 'Group'
  }
}

resource adminsAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdAdminsGroupObjectId)) {
  scope: fileShare
  name: guid(fileShare.id, avdAdminsGroupObjectId, smbShareElevatedContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', smbShareElevatedContributorRoleId)
    principalId: avdAdminsGroupObjectId
    principalType: 'Group'
  }
}
