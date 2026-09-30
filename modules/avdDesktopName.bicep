// =============================================================================
// Rename the published desktop in each application group
// =============================================================================
// Every desktop application group gets a desktop object created for it by the
// AVD service, called "SessionDesktop". That string is what users see in their
// client, and it cannot be changed with a Bicep resource: the ARM schema for
// Microsoft.DesktopVirtualization/applicationGroups/desktops exposes only
// `name`, with no friendlyName, and setting friendlyName on the application
// group does not affect it. The only route is a PATCH against the REST API.
//
// So this is a deployment script, using the same managed identity as the Entra
// work. It needs Azure RBAC rather than Graph permissions - the caller grants
// Desktop Virtualization Application Group Contributor on the AVD resource
// group, which cannot reach anything outside it.
//
// One script handles every application group, rather than one script each:
// deployment scripts each spin up a container instance, and three containers
// to set three strings is not a good trade.
// =============================================================================

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

param location string

@description('Resource ID of the user-assigned managed identity that runs the script.')
param managedIdentityId string

@description('Principal ID of that identity. The role assignment below is made for it, in this resource group.')
param managedIdentityPrincipalId string

@description('''Application groups and the desktop name each should show.
Each entry: { applicationGroup: string, desktopName: string }''')
param desktops array

param azCliVersion string = '2.85.0'

param forceUpdateTag string = utcNow()

param retainArtifacts bool = false

// Passed as JSON rather than as a flattened string, so a desktop name
// containing a space or a comma cannot break the parsing.
var desktopsJson = string(desktops)

// The identity holds Graph permissions for the Entra work, but nothing in
// Azure beyond Reader. Renaming a desktop is an ARM write, so it needs a role -
// granted here rather than in the bootstrap, so it is scoped to the resource
// group this deployment created and disappears with it.
var appGroupContributorRoleId = '86240b0e-9422-4c43-887b-b61143f32ba8'

resource appGroupContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentityPrincipalId, appGroupContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      appGroupContributorRoleId
    )
    principalId: managedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource rename 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'set-avd-desktop-names'
  tags: tags
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  dependsOn: [
    appGroupContributor
  ]
  properties: {
    azCliVersion: azCliVersion
    forceUpdateTag: forceUpdateTag
    timeout: 'PT20M'
    retentionInterval: 'PT1H'
    cleanupPreference: retainArtifacts ? 'OnExpiration' : 'OnSuccess'
    environmentVariables: [
      {
        name: 'DESKTOPS_JSON'
        value: desktopsJson
      }
      {
        name: 'SUBSCRIPTION_ID'
        value: subscription().subscriptionId
      }
      {
        name: 'RESOURCE_GROUP'
        value: resourceGroup().name
      }
      {
        // Derived rather than hardcoded, so this still works in sovereign clouds.
        name: 'ARM_ENDPOINT'
        value: environment().resourceManager
      }
    ]
    scriptContent: '''
      set -euo pipefail

      # A role assignment made moments ago is not always visible to the next
      # call. Waiting here costs nothing and avoids a first-run failure that
      # looks like a permissions problem but is really a timing one.
      sleep 45

      COUNT=$(echo "${DESKTOPS_JSON}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
      echo "Application groups to update: ${COUNT}"

      for i in $(seq 0 $((COUNT - 1))); do
        APP_GROUP=$(echo "${DESKTOPS_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin)[${i}]['applicationGroup'])")
        DESKTOP_NAME=$(echo "${DESKTOPS_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin)[${i}]['desktopName'])")

        # Build the body with json.dumps so quotes and non-ASCII in the name
        # survive intact.
        echo "${DESKTOP_NAME}" | python3 -c "
import json, sys
print(json.dumps({'properties': {'friendlyName': sys.stdin.read().rstrip('\n')}}))
" > /tmp/body.json

        URL="${ARM_ENDPOINT%/}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DesktopVirtualization/applicationGroups/${APP_GROUP}/desktops/SessionDesktop?api-version=2024-04-03"

        az rest --method PATCH --url "${URL}" \
          --headers "Content-Type=application/json" \
          --body @/tmp/body.json --output none

        echo "${APP_GROUP}/SessionDesktop -> ${DESKTOP_NAME}"
      done

      printf '{ "desktopsRenamed": %s }\n' "${COUNT}" > "${AZ_SCRIPTS_OUTPUT_PATH}"
    '''
  }
}

output desktopsRenamed int = int(rename.properties.outputs.desktopsRenamed)
