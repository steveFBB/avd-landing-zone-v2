// =============================================================================
// Finish the Entra Kerberos setup on the FSLogix storage account
// =============================================================================
// Setting directoryServiceOptions = 'AADKERB' on the storage account is done in
// storage.bicep and is the easy half. It makes the Storage resource provider
// create an application registration called
//
//   [Storage Account] <account>.file.core.windows.net
//
// That application then needs two changes before anyone can mount the share,
// neither of which ARM can express as a resource:
//
//   1. ADMIN CONSENT on its three delegated permissions (openid, profile,
//      User.Read). Without it, authentication fails.
//   2. The tag kdc_enable_cloud_group_sids on its manifest. Kerberos tickets
//      carry at most 1,010 group SIDs, and cloud-only identities need cloud
//      group SIDs in the ticket. Microsoft's wording is blunt: without this
//      tag, "authentication fails". For a cloud-only deployment it is
//      mandatory, not a tuning option.
//
// Both are Graph calls, so they run here with the same managed identity used
// for group creation.
//
// STILL MANUAL AFTERWARDS: excluding this application from any Conditional
// Access policy that requires MFA. Entra Kerberos does not support MFA, and a
// broad "require MFA for all apps" policy produces
// "System error 1327: Account restrictions are preventing this user from
// signing in". That is a security policy change and deliberately not automated.
//
// PERMISSIONS THE IDENTITY NEEDS
//   Application.ReadWrite.All             (to patch the manifest tag)
//   DelegatedPermissionGrant.ReadWrite.All (to grant the consent)
// =============================================================================

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

param location string

@description('Resource ID of the user-assigned managed identity holding the Graph permissions above.')
param managedIdentityId string

@description('Name of the FSLogix storage account. Used to find the application the Storage RP created for it.')
param storageAccountName string

param azCliVersion string = '2.85.0'

param forceUpdateTag string = utcNow()

@description('Keep the container instance and its transient storage account after a successful run, for debugging.')
param retainArtifacts bool = false

// Derived rather than hardcoded so this still works in sovereign clouds, where
// the storage suffix is not core.windows.net.
var storageAppDisplayName = '[Storage Account] ${storageAccountName}.file.${environment().suffixes.storage}'

resource kerberosSetup 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'configure-entra-kerberos'
  tags: tags
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
    timeout: 'PT30M'
    retentionInterval: 'PT1H'
    // OnSuccess already keeps the container and its storage account when a run
    // FAILS, which is what you read the events from. OnExpiration keeps them
    // after a success too, for when a script succeeded but did the wrong thing.
    cleanupPreference: retainArtifacts ? 'OnExpiration' : 'OnSuccess'
    environmentVariables: [
      {
        name: 'STORAGE_APP_DISPLAY_NAME'
        value: storageAppDisplayName
      }
    ]
    scriptContent: '''
      set -euo pipefail

      GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

      # The application is created asynchronously by the Storage resource
      # provider once AADKERB is set. It is usually there within a few seconds,
      # but "usually" is not a deployment strategy, so poll.
      FILTER=$(python3 -c "import urllib.parse,os; print(urllib.parse.quote(\"displayName eq '\" + os.environ['STORAGE_APP_DISPLAY_NAME'] + \"'\"))")

      APP_OBJECT_ID=""
      for attempt in $(seq 1 30); do
        APP_OBJECT_ID=$(az rest --method GET \
          --url "https://graph.microsoft.com/v1.0/applications?\$filter=${FILTER}&\$select=id,appId" \
          --query "value[0].id" -o tsv 2>/dev/null || true)

        if [ -n "${APP_OBJECT_ID}" ] && [ "${APP_OBJECT_ID}" != "None" ]; then
          break
        fi
        echo "Waiting for the storage account application to appear (attempt ${attempt})..."
        sleep 10
      done

      if [ -z "${APP_OBJECT_ID}" ] || [ "${APP_OBJECT_ID}" = "None" ]; then
        echo "ERROR: could not find an application named '${STORAGE_APP_DISPLAY_NAME}'." >&2
        echo "Confirm the storage account has directoryServiceOptions = AADKERB." >&2
        echo "If enabling Kerberos failed with MicrosoftGraphRequestFailed, the tenant has an" >&2
        echo "app management policy blocking the Storage resource provider from adding its own" >&2
        echo "credential. See the README." >&2
        exit 1
      fi

      APP_ID=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}?\$select=appId" \
        --query "appId" -o tsv)

      # The consent grant is written against the SERVICE PRINCIPAL, not the
      # application, and wants object IDs on both sides.
      STORAGE_SP_ID=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId%20eq%20'${APP_ID}'&\$select=id" \
        --query "value[0].id" -o tsv)

      GRAPH_SP_ID=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId%20eq%20'${GRAPH_APP_ID}'&\$select=id" \
        --query "value[0].id" -o tsv)

      # A Graph filter that matches nothing returns an empty string and exit
      # code 0, so set -e does not catch it. Left unchecked, the consent call
      # below would post an empty clientId and fail with a 400 that reads like
      # a permissions problem.
      if [ -z "${STORAGE_SP_ID}" ] || [ "${STORAGE_SP_ID}" = "None" ]; then
        echo "ERROR: no service principal found for appId ${APP_ID}." >&2
        exit 1
      fi

      if [ -z "${GRAPH_SP_ID}" ] || [ "${GRAPH_SP_ID}" = "None" ]; then
        echo "ERROR: could not resolve the Microsoft Graph service principal in this tenant." >&2
        exit 1
      fi

      echo "Application:       ${APP_OBJECT_ID}"
      echo "Service principal: ${STORAGE_SP_ID}"

      # ---------------------------------------------------------------------
      # 1. Admin consent — equivalent to the "Grant admin consent" button.
      # ---------------------------------------------------------------------
      # Graph will happily create a second grant for the same client/resource
      # pair, so check first and patch rather than POSTing blindly.
      SCOPES="openid profile User.Read"

      EXISTING_GRANT=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?\$filter=clientId%20eq%20'${STORAGE_SP_ID}'%20and%20resourceId%20eq%20'${GRAPH_SP_ID}'" \
        --query "value[0].id" -o tsv 2>/dev/null || true)

      if [ -n "${EXISTING_GRANT}" ] && [ "${EXISTING_GRANT}" != "None" ]; then
        az rest --method PATCH \
          --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/${EXISTING_GRANT}" \
          --headers "Content-Type=application/json" \
          --body "{\"scope\": \"${SCOPES}\"}" --output none
        echo "Updated existing admin consent grant."
      else
        az rest --method POST \
          --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
          --headers "Content-Type=application/json" \
          --body "{
            \"clientId\":    \"${STORAGE_SP_ID}\",
            \"consentType\": \"AllPrincipals\",
            \"principalId\": null,
            \"resourceId\":  \"${GRAPH_SP_ID}\",
            \"scope\":       \"${SCOPES}\"
          }" --output none
        echo "Granted admin consent for: ${SCOPES}"
      fi

      # ---------------------------------------------------------------------
      # 2. The cloud group SIDs tag.
      # ---------------------------------------------------------------------
      # PATCH replaces the whole tags collection, so read what is there and
      # merge. The Storage RP sets tags of its own and stripping them is the
      # kind of damage that surfaces weeks later.
      CURRENT_TAGS=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}?\$select=tags" \
        --query "tags" -o json)

      NEW_TAGS=$(python3 -c "
import json, sys
tags = json.loads(sys.argv[1]) or []
if 'kdc_enable_cloud_group_sids' not in tags:
    tags.append('kdc_enable_cloud_group_sids')
print(json.dumps(tags))
" "${CURRENT_TAGS}")

      az rest --method PATCH \
        --url "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
        --headers "Content-Type=application/json" \
        --body "{\"tags\": ${NEW_TAGS}}" --output none

      echo "Application tags now: ${NEW_TAGS}"

      printf '{ "applicationObjectId": "%s", "applicationId": "%s", "servicePrincipalObjectId": "%s" }\n' \
        "${APP_OBJECT_ID}" "${APP_ID}" "${STORAGE_SP_ID}" > "${AZ_SCRIPTS_OUTPUT_PATH}"
    '''
  }
}

@description('Object ID of the storage account application. Use this to find it when excluding it from MFA Conditional Access.')
output applicationObjectId string = kerberosSetup.properties.outputs.applicationObjectId

@description('Application (client) ID of the storage account application.')
output applicationId string = kerberosSetup.properties.outputs.applicationId
