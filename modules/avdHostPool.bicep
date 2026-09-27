// AVD host pool
//
// Pooled with depth-first load balancing: sessions fill one host before
// spilling onto the next. Cheaper than breadth-first when hosts scale down,
// at the cost of more contention on whichever host is filling.
//
// The registration token is created here with an expiry passed in from
// main.bicep, so every host pool in a deployment shares the same window.
// It is deliberately NOT exposed as an output — deployment outputs are
// retained in deployment history, and a registration token is a short-lived
// credential. Fetch it when you need it:
//
//   az desktopvirtualization hostpool retrieve-registration-token \
//     --resource-group <rg> --host-pool-name <name>

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

param location string
param hostPoolName string
param friendlyName string

@description('Maximum concurrent sessions per session host. Depends on VM size — roughly 6-8 for 2 vCPU, 10-12 for 4 vCPU, 16-20 for 8 vCPU.')
@minValue(1)
@maxValue(999)
param maxSessionLimit int

@description('Power hosts on when a user connects. Requires the AVD service principal to hold Desktop Virtualization Power On Contributor on the session host subscription — a one-time step outside this template.')
param startVMOnConnect bool

@description('''Custom RDP properties, semicolon separated.

targetisaadjoined:i:1 is not optional for this design. Session hosts are
Entra-joined, and without it a connection from any client that is not Entra
joined to the same tenant is refused — which includes the web, macOS, iOS and
Android clients always, and a Windows PC that is merely signed in rather than
joined. The symptom is a credential prompt that never accepts a correct
password, with nothing logged that points at the cause.

enablerdsaadauth:i:1 would add single sign-on, but it needs a Kerberos server
object and a consent step that are outside this template, so it is not set
here.''')
param customRdpProperties string = 'targetisaadjoined:i:1;'

@description('Registration token expiry, as an ISO 8601 timestamp. Session hosts must register before it passes.')
param registrationTokenExpiry string

@description('Log Analytics workspace resource ID for diagnostics. Empty string skips the diagnostic setting.')
param logAnalyticsWorkspaceId string = ''

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolName
  tags: tags
  location: location
  properties: {
    friendlyName: friendlyName
    customRdpProperty: customRdpProperties
    hostPoolType: 'Pooled'
    loadBalancerType: 'DepthFirst'
    maxSessionLimit: maxSessionLimit
    // Desktop, because this template deploys a desktop application group.
    // Change to RailApplications only if a RemoteApp group becomes the
    // primary experience.
    preferredAppGroupType: 'Desktop'
    startVMOnConnect: startVMOnConnect
    validationEnvironment: false
    registrationInfo: {
      expirationTime: registrationTokenExpiry
      // 'Update' refreshes the token on redeployment, so it does not go
      // stale. It does mean an unrelated redeployment rotates the token.
      registrationTokenOperation: 'Update'
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  scope: hostPool
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

output hostPoolId string = hostPool.id
output hostPoolName string = hostPool.name
