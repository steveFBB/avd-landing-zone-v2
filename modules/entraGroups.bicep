// =============================================================================
// AVD access groups in Microsoft Entra ID
// =============================================================================
// WHY THIS IS A DEPLOYMENT SCRIPT AND NOT THE GRAPH BICEP EXTENSION
//
// The Microsoft Graph Bicep extension went GA in July 2025 and would express
// this in six lines. It cannot be used here. Extensions that need the OAuth
// on-behalf-of flow fail with 401 inside a Template Spec, and the Azure portal's
// deployment flow carries no Graph token at all — the documented symptom is
// "Insufficient privileges to complete the operation". Microsoft has an open
// issue for it with no committed date.
//
// A deployment script with a user-assigned managed identity does carry an
// app-only Graph token, which is why this works from a portal Create blade.
// The cost is the one-time bootstrap that grants the identity its Graph app
// roles — see scripts/bootstrap-entra-identity.ps1.
//
// PERMISSIONS THE IDENTITY NEEDS
//   Group.ReadWrite.All   (Graph, application)
//   Reader                (Azure RBAC, subscription) — only so the container's
//                         automatic `az login --identity` finds a subscription
//
// Group.Create alone is not enough: the script reads before it writes, so that
// re-running the deployment does not create duplicate groups.
// =============================================================================

param location string

@description('Resource ID of the user-assigned managed identity holding Group.ReadWrite.All.')
param managedIdentityId string

@description('Display name for the AVD users group.')
param usersGroupName string

@description('Display name for the AVD admins group.')
param adminsGroupName string

@description('Azure CLI version for the script container. Bump if a command needs something newer.')
param azCliVersion string = '2.85.0'

@description('Forces the script to re-run on redeployment. Deployment scripts are skipped when nothing about them changes.')
param forceUpdateTag string = utcNow()

@description('Keep the container instance and its transient storage account after a successful run, for debugging.')
param retainArtifacts bool = false

resource groups 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'create-avd-entra-groups'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    azCliVersion: azCliVersion
    forceUpdateTag: forceUpdateTag
    timeout: 'PT20M'
    retentionInterval: 'PT1H'
    // OnSuccess already keeps the container and its storage account when a run
    // FAILS, which is what you read the events from. OnExpiration keeps them
    // after a success too, for when a script succeeded but did the wrong thing.
    cleanupPreference: retainArtifacts ? 'OnExpiration' : 'OnSuccess'
    environmentVariables: [
      {
        name: 'USERS_GROUP_NAME'
        value: usersGroupName
      }
      {
        name: 'ADMINS_GROUP_NAME'
        value: adminsGroupName
      }
    ]
    scriptContent: '''
      set -euo pipefail

      # Create the group if it does not already exist, and echo its object ID.
      # Matching on displayName is what makes redeployment safe: without it,
      # every run would add another group with the same name, since Entra
      # permits duplicates.
      ensure_group() {
        local name="$1"
        local existing

        existing=$(az rest --method GET \
          --url "https://graph.microsoft.com/v1.0/groups?\$filter=displayName eq '${name}'&\$select=id" \
          --query "value[0].id" -o tsv 2>/dev/null || true)

        if [ -n "${existing}" ] && [ "${existing}" != "None" ]; then
          echo "${existing}"
          return 0
        fi

        # mailNickname is mandatory even for a security group that will never
        # receive mail. Strip anything Entra rejects in it.
        local nickname
        nickname=$(echo "${name}" | tr -cd '[:alnum:]-')

        az rest --method POST \
          --url "https://graph.microsoft.com/v1.0/groups" \
          --headers "Content-Type=application/json" \
          --body "{
            \"displayName\":    \"${name}\",
            \"mailNickname\":   \"${nickname}\",
            \"description\":    \"Created by the AVD landing zone deployment\",
            \"mailEnabled\":    false,
            \"securityEnabled\": true
          }" --query id -o tsv
      }

      USERS_ID=$(ensure_group "${USERS_GROUP_NAME}")
      ADMINS_ID=$(ensure_group "${ADMINS_GROUP_NAME}")

      echo "Users group:  ${USERS_GROUP_NAME} = ${USERS_ID}"
      echo "Admins group: ${ADMINS_GROUP_NAME} = ${ADMINS_ID}"

      # New groups take a few seconds to become usable as a role assignment
      # principal. Without this pause the role assignments that follow can fail
      # with PrincipalNotFound on a fresh tenant.
      sleep 30

      # printf rather than a heredoc: a heredoc terminator has to sit at column
      # zero, which reads badly inside an indented Bicep string and fails
      # silently when it slips — bash just warns and writes the terminator into
      # the file, and the deployment then dies parsing the output as JSON.
      printf '{ "usersGroupObjectId": "%s", "adminsGroupObjectId": "%s" }\n' \
        "${USERS_ID}" "${ADMINS_ID}" > "${AZ_SCRIPTS_OUTPUT_PATH}"
    '''
  }
}

output usersGroupObjectId string = groups.properties.outputs.usersGroupObjectId
output adminsGroupObjectId string = groups.properties.outputs.adminsGroupObjectId
