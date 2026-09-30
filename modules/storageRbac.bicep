// Azure RBAC for FSLogix share access
//
// Grants two Entra ID groups access to the storage account:
//   users  -> Storage File Data SMB Share Contributor (read/write)
//   admins -> Storage File Data SMB Share Elevated Contributor
//             (read/write plus the ability to modify NTFS ACLs)
//
// Both group IDs are optional. An empty string skips that assignment, so the
// template still deploys before the groups exist.
//
// This controls WHO can reach the share. It does not set the NTFS permissions
// on files and directories inside it - that is fslogixNtfsPermissions.bicep,
// which needs a mounted client and so runs on a session host.
//
// SCOPE: THE STORAGE ACCOUNT, NOT THE SHARE
//
// A share-scoped assignment is tighter - it would not extend to a second share
// added to the same account later - but Azure RBAC only surfaces assignments
// made at the scope you are looking at or above it. A share-scoped assignment
// is therefore invisible on the storage account's Access Control blade, which
// is the first place any administrator looks. The predictable result is
// someone seeing an empty list, adding the role at account scope themselves,
// and leaving two assignments at different scopes doing the same job.
//
// A permission model nobody can see is worse than a slightly broader one, so
// these are assigned at the account. The trade is real though: if this account
// ever gains a second file share - MSIX app attach, a department share - these
// groups reach it too. Put other shares on another account, or move these
// assignments down to the share and accept the visibility cost.
//
// Role definition IDs are Microsoft's built-in ones and are stable.

param storageAccountName string

@description('Entra ID object ID of the AVD users group. Empty string skips the assignment.')
param avdUsersGroupObjectId string = ''

@description('Entra ID object ID of the AVD admins group. Empty string skips the assignment.')
param avdAdminsGroupObjectId string = ''

var smbShareContributorRoleId = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
var smbShareElevatedContributorRoleId = 'a7264617-510b-434b-a828-9731dc254ea7'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// guid() over the scope, principal and role makes these names deterministic,
// so redeploying updates the same assignment rather than creating another.
resource usersAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdUsersGroupObjectId)) {
  scope: storageAccount
  name: guid(storageAccount.id, avdUsersGroupObjectId, smbShareContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', smbShareContributorRoleId)
    principalId: avdUsersGroupObjectId
    principalType: 'Group'
  }
}

resource adminsAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdAdminsGroupObjectId)) {
  scope: storageAccount
  name: guid(storageAccount.id, avdAdminsGroupObjectId, smbShareElevatedContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', smbShareElevatedContributorRoleId)
    principalId: avdAdminsGroupObjectId
    principalType: 'Group'
  }
}
