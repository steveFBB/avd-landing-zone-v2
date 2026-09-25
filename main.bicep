// =============================================================================
// AVD landing zone — v2 (loop-based)
// =============================================================================
// Stage 2: hub + spokes, NSGs, route tables, peerings.
//
// Identity model: CLOUD-ONLY. FSLogix storage will use Microsoft Entra
// Kerberos with cloud-only identities, so no domain controller, no custom
// VNet DNS, and no on-premises connectivity are required. Session hosts
// must be Entra-joined, and must run Windows 11 24H2+ or Server 2025 —
// cloud-only Entra Kerberos does not support older builds.
//
// Unlike v1, the number of spokes and subnets is not fixed. Spokes are
// defined as an array and looped; each spoke's subnets are matched to it by
// name. One spoke or five, same code.
//
// Names are DERIVED, not supplied:
//   rg-<spoke>              e.g. rg-avd
//   vnet-<spoke>            e.g. vnet-avd
//   snet-<spoke>-<subnet>   e.g. snet-avd-hosts
//   nsg-<spoke>-<subnet>    e.g. nsg-avd-hosts
//   rt-<spoke>              e.g. rt-avd
//
// Still to come: storage + private endpoint + DNS, Log Analytics and
// diagnostics, AVD control plane.
// =============================================================================

targetScope = 'subscription'

param location string

//
// HUB
//
param hubRgName string
param hubVnetName string
param hubAddressPrefix string
param gatewaySubnetPrefix string

@description('Hub firewall type. \'none\' creates no NVA subnets and no spoke route tables. \'fortigate\' creates the four FortiGate NIC subnets, creates a route table per spoke pointing at the firewall, and enables forwarded traffic on all peerings.')
@allowed([
  'none'
  'fortigate'
])
param hubFirewallType string

@description('Internal IP of the hub firewall NVA. Required when hubFirewallType is not \'none\'. Must sit inside fgtInternalPrefix.')
param hubFirewallInternalIp string = ''

param fgtExternalPrefix string = ''
param fgtInternalPrefix string = ''
param fgtHaPrefix string = ''
param fgtMgmtPrefix string = ''

@description('Create AzureBastionSubnet in the hub. Subnet only — no Bastion host is deployed.')
param deployBastionSubnet bool = false

@description('Prefix for AzureBastionSubnet. Azure requires /26 or larger.')
param bastionSubnetPrefix string = ''

//
// SPOKES
//
@description('''Spokes to create. One row per spoke in the GUI.
Each entry: {
  name          string  short name, e.g. 'avd' — drives all derived names
  addressPrefix string  e.g. '10.3.0.0/16'
  role          string  'avd' (hosts session hosts and the storage private
                        endpoint) or 'none'
  peerToHub     bool    create hub<->spoke peerings in both directions
  natGateway    bool    create a NAT gateway + public IP in this spoke.
                        Costs money per spoke — a NAT gateway cannot be
                        shared across VNets. Which subnets actually use it
                        is set per subnet below.
}''')
param spokes array

@description('''Subnets, matched to their parent spoke by the `spoke` field.
Each entry: {
  spoke                 string  must match a spokes[].name
  name                  string  short name — becomes snet-<spoke>-<name>
  prefix                string  e.g. '10.3.0.0/24'
  nsgType               string  'avd' (documented AVD outbound allow rules)
                                or 'empty'
  useNatGateway         bool    attach to the spoke's NAT gateway. Ignored
                                when the spoke has natGateway = false.
  hostsPrivateEndpoints bool    the FSLogix private endpoint lands here, and
                                this subnet gets private endpoint network
                                policies disabled. Exactly one subnet in the
                                AVD spoke should have this set.
}''')
param subnets array

@description('''Set spoke subnets private (defaultOutboundAccess = false), removing
Azure's implicit outbound internet path. Azure is retiring default outbound access
for VNets created with API versions after 31 March 2026; setting this true makes
behaviour explicit rather than dependent on the template's API version.

A subnet that is private with no NAT gateway and no route to a firewall has NO
outbound internet. The deployment still succeeds — the failure shows up later as
session hosts unable to reach the AVD service. Check the spokesWithoutOutbound
output.''')
param privateSubnets bool = true

//
// STORAGE
//
@description('Deploy the FSLogix storage account, share, private endpoint and DNS. Off means no storage at all.')
param deployStorage bool = true

@description('Resource group for the storage account and its private DNS zone. Must not collide with a spoke name, since spokes create rg-<name>.')
param storageRgName string = 'rg-storage'

@description('Globally unique across all of Azure. Lowercase letters and digits only, 3-24 characters.')
param storageAccountName string = ''

param storageSku string = 'Premium_LRS'
param storageAccountKind string = 'FileStorage'
param storageAccessTier string = 'Hot'
param fileShareName string = 'profiles'
param fileShareQuotaGiB int = 512

param storageMinimumTlsVersion string = 'TLS1_2'
param storageSupportsHttpsTrafficOnly bool = true
param storageAllowBlobPublicAccess bool = false
param storageAllowSharedKeyAccess bool = true
param storagePublicNetworkAccess string = 'Enabled'
param storageLargeFileSharesState string = 'Enabled'

param fslogixPrivateEndpointName string = 'pe-fslogix-file'

@description('Entra ID object ID of the AVD users group. Empty skips the role assignment.')
param avdUsersGroupObjectId string = ''

@description('Entra ID object ID of the AVD admins group. Empty skips the role assignment.')
param avdAdminsGroupObjectId string = ''

//
// MONITORING
//
@description('Deploy the Log Analytics workspace and send VNet and storage diagnostics to it.')
param deployMonitoring bool = true

@description('Resource group for the Log Analytics workspace. Must not collide with a spoke name.')
param monitoringRgName string = 'rg-mgmt'

param logAnalyticsWorkspaceName string = 'law-avd'
param logAnalyticsRetentionDays int = 30
param logAnalyticsSku string = 'PerGB2018'

//
// AVD CONTROL PLANE
//
@description('''Host pools to create. One row per host pool in the GUI.
Each entry: {
  name             string  short name — becomes hp-<name> and ag-<name>-desktop
  friendlyName     string  what users see in the AVD client
  maxSessionLimit  int     concurrent sessions per session host
  startVMOnConnect bool    power hosts on when a user connects
}
An empty array deploys no control plane at all. Every host pool gets its own
desktop application group; all of them surface through the single workspace.
All pools are Pooled with depth-first load balancing.''')
param hostPools array = []

param avdWorkspaceName string = 'ws-avd'
param avdWorkspaceFriendlyName string = 'AVD Workspace'

@description('''Registration token expiry as an ISO 8601 timestamp, shared by every
host pool. The default is 30 days from deployment time — do not set this in the
parameters file unless you have a reason to.

The token is not returned as an output, because deployment outputs persist in
deployment history. Fetch it with:
  az desktopvirtualization hostpool retrieve-registration-token \\
    --resource-group <rg> --host-pool-name <name>''')
param registrationTokenExpiry string = dateTimeAdd(utcNow(), 'P30D')

//
// DERIVED
//
var hubHasFirewall = hubFirewallType != 'none'

// NVA-forwarded traffic must be allowed across peerings in both directions,
// or the firewall's forwarded spoke-to-spoke traffic is dropped at the
// peering rather than reaching the destination spoke.
var peeringAllowForwardedTraffic = hubHasFirewall

// Flatten spokes x their subnets into one list so NSGs (which are per
// subnet) can be created in a single flat loop. Bicep handles one flat
// loop far better than a nested one.
var spokeSubnets = [
  for subnet in subnets: {
    spoke: subnet.spoke
    name: subnet.name
    prefix: subnet.prefix
    nsgType: subnet.nsgType
    useNatGateway: subnet.useNatGateway
    hostsPrivateEndpoints: subnet.hostsPrivateEndpoints
    nsgName: 'nsg-${subnet.spoke}-${subnet.name}'
    rgName: 'rg-${subnet.spoke}'
  }
]

// Locate the AVD spoke and the subnet that will host the private endpoint.
//
// Resource IDs are CONSTRUCTED here rather than read from module outputs.
// Reading them would mean indexing one loop's outputs from inside another,
// which Bicep does not support. Every name involved is derived from
// parameters, so building the ID directly is deterministic and safe —
// ordering is handled with dependsOn instead.
var avdSpokes = filter(spokes, s => s.role == 'avd')
var hasAvdSpoke = !empty(avdSpokes)
var avdSpokeName = hasAvdSpoke ? first(avdSpokes).name : ''

var peSubnets = filter(subnets, s => s.spoke == avdSpokeName && s.hostsPrivateEndpoints)
var hasPeSubnet = hasAvdSpoke && !empty(peSubnets)
var peSubnetName = hasPeSubnet ? first(peSubnets).name : ''

var peSubnetId = hasPeSubnet
  ? resourceId(
      subscription().subscriptionId,
      'rg-${avdSpokeName}',
      'Microsoft.Network/virtualNetworks/subnets',
      'vnet-${avdSpokeName}',
      'snet-${avdSpokeName}-${peSubnetName}'
    )
  : ''

// Every VNet that must resolve the FSLogix share: the hub plus all spokes.
// Linking a VNet to a private DNS zone costs nothing, so there is no reason
// to be selective here.
// A for-expression can only be the direct value of a declaration, not an
// argument to a function, so the spoke list is built separately and then
// concatenated.
var spokeVnetLinks = [
  for spoke in spokes: {
    name: 'vnet-${spoke.name}'
    id: resourceId(
      subscription().subscriptionId,
      'rg-${spoke.name}',
      'Microsoft.Network/virtualNetworks',
      'vnet-${spoke.name}'
    )
  }
]

var hubVnetLink = [
  {
    name: hubVnetName
    id: resourceId(
      subscription().subscriptionId,
      hubRgName,
      'Microsoft.Network/virtualNetworks',
      hubVnetName
    )
  }
]

var dnsLinkedVnets = concat(hubVnetLink, spokeVnetLinks)

// Spokes derive rg-<name>, so a spoke called 'storage' or 'mgmt' would
// collide with the shared resource groups and the two deployments would
// fight over the same RG.
var sharedRgNames = union(
  deployStorage ? [storageRgName] : [],
  deployMonitoring ? [monitoringRgName] : [],
  [hubRgName]
)
var spokeRgNames = [for spoke in spokes: 'rg-${spoke.name}']
var rgNameCollisions = filter(spokeRgNames, r => contains(sharedRgNames, r))

// The control plane lives in the AVD spoke's resource group, so it needs an
// AVD spoke to exist. Host pools defined without one are skipped rather
// than deployed somewhere arbitrary.
var deployControlPlane = hasAvdSpoke && !empty(hostPools)
var avdRgName = 'rg-${avdSpokeName}'
var hostPoolNameList = [for pool in hostPools: 'hp-${pool.name}']

// Diagnostics on control plane resources are wired only when monitoring is
// deployed; an empty workspace ID skips them inside each module.
var avdDiagnosticsWorkspaceId = deployMonitoring ? logAnalytics!.outputs.workspaceId : ''

// A spoke has an outbound internet path if it routes through the hub
// firewall, or has a NAT gateway with at least one subnet attached to it.
// Anything else is a spoke whose VMs cannot reach the internet once its
// subnets are private — which for an AVD spoke means session hosts that
// never register.
var spokesWithoutOutboundList = [
  for spoke in spokes: (hubHasFirewall || (spoke.natGateway && !empty(filter(
    subnets,
    s => s.spoke == spoke.name && s.useNatGateway
  )))) ? '' : spoke.name
]

//
// RESOURCE GROUPS — one per spoke
//
resource hubRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: hubRgName
  location: location
}

resource spokeRgs 'Microsoft.Resources/resourceGroups@2024-03-01' = [
  for spoke in spokes: {
    name: 'rg-${spoke.name}'
    location: location
  }
]

//
// HUB VNET
//
module hub 'modules/hub.bicep' = {
  name: 'hub'
  scope: hubRg
  params: {
    location: location
    vnetName: hubVnetName
    addressPrefix: hubAddressPrefix
    gatewaySubnetPrefix: gatewaySubnetPrefix
    firewallType: hubFirewallType
    fgtExternalPrefix: fgtExternalPrefix
    fgtInternalPrefix: fgtInternalPrefix
    fgtHaPrefix: fgtHaPrefix
    fgtMgmtPrefix: fgtMgmtPrefix
    deployBastionSubnet: deployBastionSubnet
    bastionSubnetPrefix: bastionSubnetPrefix
  }
}

//
// NSGS — one per subnet, flat loop
//
module nsgs 'modules/nsg.bicep' = [
  for (s, i) in spokeSubnets: {
    name: 'nsg-${s.spoke}-${s.name}'
    scope: resourceGroup(s.rgName)
    dependsOn: [
      spokeRgs
    ]
    params: {
      location: location
      nsgName: s.nsgName
      nsgType: s.nsgType
    }
  }
]

//
// ROUTE TABLES — one per spoke, only when the hub has a firewall
//
module routeTables 'modules/routeTable.bicep' = [
  for (spoke, i) in spokes: if (hubHasFirewall) {
    name: 'rt-${spoke.name}'
    scope: resourceGroup('rg-${spoke.name}')
    dependsOn: [
      spokeRgs
    ]
    params: {
      location: location
      routeTableName: 'rt-${spoke.name}'
      firewallInternalIp: hubFirewallInternalIp
    }
  }
]

//
// NAT GATEWAYS — one per spoke that asks for one
//
// A NAT gateway cannot be attached to subnets in more than one VNet, so
// spokes cannot share. Each one carries its own public IP and its own
// monthly cost, which is why this is opt-in per spoke.
//
module natGateways 'modules/natGateway.bicep' = [
  for (spoke, i) in spokes: if (spoke.natGateway) {
    name: 'nat-${spoke.name}'
    scope: resourceGroup('rg-${spoke.name}')
    dependsOn: [
      spokeRgs
    ]
    params: {
      location: location
      natGatewayName: 'nat-${spoke.name}'
      publicIpName: 'pip-nat-${spoke.name}'
    }
  }
]

//
// SPOKE VNETS
//
// Each spoke module receives only its own subnets, with the matching NSG
// and route table IDs already resolved. filter() selects this spoke's
// subnets; the index lookup into nsgs[] finds the NSG built for each.
//
module spokeVnets 'modules/spoke.bicep' = [
  for (spoke, si) in spokes: {
    name: 'spoke-${spoke.name}'
    scope: resourceGroup('rg-${spoke.name}')
    dependsOn: [
      spokeRgs
      nsgs
      routeTables
      natGateways
    ]
    params: {
      location: location
      spokeName: spoke.name
      addressPrefix: spoke.addressPrefix
      // filter() selects this spoke's subnets; map() reshapes them for the
      // module. NSGs are passed by name — see spoke.bicep for why.
      subnets: map(
        filter(spokeSubnets, s => s.spoke == spoke.name),
        s => {
          name: s.name
          prefix: s.prefix
          nsgName: s.nsgName
          useNatGateway: s.useNatGateway
          hostsPrivateEndpoints: s.hostsPrivateEndpoints
        }
      )
      routeTableName: hubHasFirewall ? 'rt-${spoke.name}' : ''
      natGatewayName: spoke.natGateway ? 'nat-${spoke.name}' : ''
      privateSubnets: privateSubnets
    }
  }
]

//
// PEERINGS — two per spoke that opts in
//
module hubToSpoke 'modules/peering.bicep' = [
  for (spoke, i) in spokes: if (spoke.peerToHub) {
    name: 'peer-hub-to-${spoke.name}'
    scope: hubRg
    params: {
      localVnetName: hubVnetName
      remoteVnetId: spokeVnets[i].outputs.vnetId
      peeringName: 'hub-to-${spoke.name}'
      allowForwardedTraffic: peeringAllowForwardedTraffic
      allowGatewayTransit: false
      useRemoteGateways: false
    }
  }
]

module spokeToHub 'modules/peering.bicep' = [
  for (spoke, i) in spokes: if (spoke.peerToHub) {
    name: 'peer-${spoke.name}-to-hub'
    scope: resourceGroup('rg-${spoke.name}')
    params: {
      localVnetName: spokeVnets[i].outputs.vnetName
      remoteVnetId: hub.outputs.vnetId
      peeringName: '${spoke.name}-to-hub'
      allowForwardedTraffic: peeringAllowForwardedTraffic
      allowGatewayTransit: false
      useRemoteGateways: false
    }
  }
]

//
// STORAGE
//
// One account shared across every host pool, in its own resource group.
//
resource storageRg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployStorage) {
  name: storageRgName
  location: location
}

module storage 'modules/storage.bicep' = if (deployStorage) {
  name: 'storage'
  scope: resourceGroup(storageRgName)
  dependsOn: [
    storageRg
  ]
  params: {
    location: location
    storageAccountName: storageAccountName
    storageSku: storageSku
    storageAccountKind: storageAccountKind
    storageAccessTier: storageAccessTier
    fileShareName: fileShareName
    fileShareQuotaGiB: fileShareQuotaGiB
    minimumTlsVersion: storageMinimumTlsVersion
    supportsHttpsTrafficOnly: storageSupportsHttpsTrafficOnly
    allowBlobPublicAccess: storageAllowBlobPublicAccess
    allowSharedKeyAccess: storageAllowSharedKeyAccess
    publicNetworkAccess: storagePublicNetworkAccess
    largeFileSharesState: storageLargeFileSharesState
  }
}

// Private DNS zone, VNet links and the private endpoint. Only possible when
// a subnet has been flagged to host it.
module fslogixPrivateAccess 'modules/fslogixPrivateAccess.bicep' = if (deployStorage && hasPeSubnet) {
  name: 'fslogixPrivateAccess'
  scope: resourceGroup(storageRgName)
  dependsOn: [
    spokeVnets
    hub
  ]
  params: {
    location: location
    storageAccountId: storage!.outputs.storageAccountId
    privateEndpointSubnetId: peSubnetId
    privateEndpointName: fslogixPrivateEndpointName
    linkedVnets: dnsLinkedVnets
  }
}

module storageRbac 'modules/storageRbac.bicep' = if (deployStorage) {
  name: 'storageRbac'
  scope: resourceGroup(storageRgName)
  params: {
    storageAccountName: storage!.outputs.storageAccountName
    fileShareName: storage!.outputs.fileShareName
    avdUsersGroupObjectId: avdUsersGroupObjectId
    avdAdminsGroupObjectId: avdAdminsGroupObjectId
  }
}

//
// MONITORING
//
resource monitoringRg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployMonitoring) {
  name: monitoringRgName
  location: location
}

module logAnalytics 'modules/logAnalytics.bicep' = if (deployMonitoring) {
  name: 'logAnalytics'
  scope: resourceGroup(monitoringRgName)
  dependsOn: [
    monitoringRg
  ]
  params: {
    location: location
    workspaceName: logAnalyticsWorkspaceName
    retentionInDays: logAnalyticsRetentionDays
    sku: logAnalyticsSku
  }
}

module hubVnetDiagnostics 'modules/vnetDiagnostics.bicep' = if (deployMonitoring) {
  name: 'diag-hub'
  scope: hubRg
  dependsOn: [
    hub
  ]
  params: {
    vnetName: hubVnetName
    workspaceId: logAnalytics!.outputs.workspaceId
  }
}

module spokeVnetDiagnostics 'modules/vnetDiagnostics.bicep' = [
  for (spoke, i) in spokes: if (deployMonitoring) {
    name: 'diag-${spoke.name}'
    scope: resourceGroup('rg-${spoke.name}')
    dependsOn: [
      spokeVnets
    ]
    params: {
      vnetName: 'vnet-${spoke.name}'
      workspaceId: logAnalytics!.outputs.workspaceId
    }
  }
]

module storageDiagnostics 'modules/storageDiagnostics.bicep' = if (deployMonitoring && deployStorage) {
  name: 'diag-storage'
  scope: resourceGroup(storageRgName)
  params: {
    storageAccountName: storage!.outputs.storageAccountName
    workspaceId: logAnalytics!.outputs.workspaceId
  }
}

//
// AVD CONTROL PLANE
//
// Host pool -> application group -> workspace. Each host pool gets its own
// desktop application group; the single workspace references all of them.
//
module avdHostPools 'modules/avdHostPool.bicep' = [
  for (pool, i) in hostPools: if (deployControlPlane) {
    name: 'hp-${pool.name}'
    scope: resourceGroup(avdRgName)
    dependsOn: [
      spokeRgs
    ]
    params: {
      location: location
      hostPoolName: 'hp-${pool.name}'
      friendlyName: pool.friendlyName
      maxSessionLimit: pool.maxSessionLimit
      startVMOnConnect: pool.startVMOnConnect
      registrationTokenExpiry: registrationTokenExpiry
      logAnalyticsWorkspaceId: avdDiagnosticsWorkspaceId
    }
  }
]

module avdApplicationGroups 'modules/avdApplicationGroup.bicep' = [
  for (pool, i) in hostPools: if (deployControlPlane) {
    name: 'ag-${pool.name}'
    scope: resourceGroup(avdRgName)
    params: {
      location: location
      applicationGroupName: 'ag-${pool.name}-desktop'
      friendlyName: pool.friendlyName
      hostPoolId: avdHostPools[i]!.outputs.hostPoolId
      // Assigning the users group here is what makes the desktop visible
      // in the client. Without it the deployment succeeds and nobody can
      // see anything.
      avdUsersGroupObjectId: avdUsersGroupObjectId
      logAnalyticsWorkspaceId: avdDiagnosticsWorkspaceId
    }
  }
]

module avdWorkspace 'modules/avdWorkspace.bicep' = if (deployControlPlane) {
  name: 'avdWorkspace'
  scope: resourceGroup(avdRgName)
  params: {
    location: location
    workspaceName: avdWorkspaceName
    friendlyName: avdWorkspaceFriendlyName
    applicationGroupReferences: [
      for (pool, i) in hostPools: avdApplicationGroups[i]!.outputs.applicationGroupId
    ]
    logAnalyticsWorkspaceId: avdDiagnosticsWorkspaceId
  }
}

//
// OUTPUTS
//
output hubVnetId string = hub.outputs.vnetId
output spokeVnetIds array = [for (spoke, i) in spokes: spokeVnets[i].outputs.vnetId]

// false means bastionSubnetPrefix is smaller than /26, which Azure rejects.
output bastionPrefixValid bool = hub.outputs.bastionPrefixValid

@description('''Spokes with no outbound internet path — no hub firewall route and no
NAT gateway attached to any of their subnets. Empty is what you want. A non-empty
list does NOT fail the deployment: it succeeds and the VMs simply cannot reach the
internet, which for an AVD spoke means session hosts that never register. Check
this before deploying.''')
output spokesWithoutOutbound array = filter(spokesWithoutOutboundList, s => !empty(s))

@description('Resource ID of the FSLogix storage account, empty when storage is not deployed.')
output storageAccountId string = deployStorage ? storage!.outputs.storageAccountId : ''

@description('Resource ID of the Log Analytics workspace, empty when monitoring is not deployed.')
output logAnalyticsWorkspaceId string = deployMonitoring ? logAnalytics!.outputs.workspaceId : ''

@description('''True when storage was requested but no subnet was flagged with
hostsPrivateEndpoints, so the share has no private endpoint and is reachable only
over its public endpoint. Flag only — the deployment still succeeds.''')
output storageHasNoPrivateEndpoint bool = deployStorage && !hasPeSubnet

@description('''Resource group names produced by a spoke that clash with the hub,
storage or monitoring resource group. Empty is what you want. A clash means two
parts of the deployment target the same resource group — rename the spoke or the
shared group.''')
output resourceGroupNameCollisions array = rgNameCollisions

@description('''True when host pools were defined but no spoke has role 'avd', so the
control plane has no resource group to live in and was skipped entirely. Set a
spoke's role to 'avd' to fix.''')
output hostPoolsSkippedNoAvdSpoke bool = !empty(hostPools) && !hasAvdSpoke

@description('Resource ID of the AVD workspace, empty when no control plane was deployed.')
output avdWorkspaceId string = deployControlPlane ? avdWorkspace!.outputs.workspaceId : ''

@description('''Names of the host pools created. Fetch a registration token with:
az desktopvirtualization hostpool retrieve-registration-token --resource-group <rg> --host-pool-name <name>''')
output hostPoolNames array = deployControlPlane ? hostPoolNameList : []
