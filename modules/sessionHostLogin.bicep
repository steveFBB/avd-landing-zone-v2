// =============================================================================
// Sign-in rights on Entra-joined session hosts
// =============================================================================
// Two separate things have to be true before a user can reach a desktop:
//
//   1. The desktop is published to them - the Desktop Virtualization User role
//      on the application group. That is done in avdApplicationGroup.bicep.
//   2. They are allowed to log on to the VM itself - Virtual Machine User
//      Login, here.
//
// Miss the second and the desktop appears in the client, the connection is
// accepted, and then the sign-in is refused. It is one of the more confusing
// AVD failure modes, because nothing in the AVD blade looks wrong.
//
// Assigned at resource group scope so it covers hosts added later without
// another deployment.
// =============================================================================

@description('Entra ID object ID of the AVD users group. Empty skips the assignment.')
param avdUsersGroupObjectId string = ''

@description('Entra ID object ID of the AVD admins group. Empty skips the assignment.')
param avdAdminsGroupObjectId string = ''

var virtualMachineUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
var virtualMachineAdminLoginRoleId = '1c0163c0-47e6-4577-8991-ea5c82e286e4'

resource usersLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdUsersGroupObjectId)) {
  name: guid(resourceGroup().id, avdUsersGroupObjectId, virtualMachineUserLoginRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      virtualMachineUserLoginRoleId
    )
    principalId: avdUsersGroupObjectId
    principalType: 'Group'
  }
}

// Admins get administrator login, which also grants user login - so they are
// deliberately not given both.
resource adminsLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdAdminsGroupObjectId)) {
  name: guid(resourceGroup().id, avdAdminsGroupObjectId, virtualMachineAdminLoginRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      virtualMachineAdminLoginRoleId
    )
    principalId: avdAdminsGroupObjectId
    principalType: 'Group'
  }
}
