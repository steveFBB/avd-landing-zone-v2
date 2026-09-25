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
  spoke         string  must match a spokes[].name
  name          string  short name, e.g. 'hosts' — becomes snet-<spoke>-<name>
  prefix        string  e.g. '10.3.0.0/24'
  nsgType       string  'avd' (documented AVD outbound allow rules) or 'empty'
  useNatGateway bool    attach this subnet to its spoke's NAT gateway.
                        Ignored when the spoke has natGateway = false.
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
    nsgName: 'nsg-${subnet.spoke}-${subnet.name}'
    rgName: 'rg-${subnet.spoke}'
  }
]

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
          // The storage private endpoint lands in the AVD spoke, and a
          // subnet hosting a private endpoint needs this policy disabled.
          disablePeNetworkPolicies: spoke.role == 'avd'
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
