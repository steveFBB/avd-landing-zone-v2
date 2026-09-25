// Spoke VNet
//
// One instance per entry in the `spokes` array in main.bicep. Creates the
// VNet and loops over whichever subnets were assigned to this spoke.
//
// The subnet loop lives here rather than in main.bicep deliberately: Bicep
// handles nested loops (spokes -> their subnets) badly, so main.bicep loops
// spokes and each spoke module loops its own subnets.
//
// NSGs, the route table and the NAT gateway are referenced by NAME and
// resolved here as `existing`, rather than having their resource IDs passed
// in. That avoids indexing one loop's module outputs from inside another
// loop in main.bicep, which Bicep does not handle. They all live in this
// module's resource group, and main.bicep orders their creation with
// dependsOn.
//
// Naming is derived, not supplied:
//   vnet-<spoke>            e.g. vnet-avd
//   snet-<spoke>-<subnet>   e.g. snet-avd-hosts

param location string

@description('Spoke short name, e.g. \'avd\'. Used to derive resource names.')
param spokeName string

param addressPrefix string

@description('''Subnets for this spoke, already filtered by main.bicep. Each:
{ name, prefix, nsgName, useNatGateway, hostsPrivateEndpoints }''')
param subnets array

@description('Name of the route table to attach to every subnet in this spoke. Empty string attaches none.')
param routeTableName string = ''

@description('Name of this spoke\'s NAT gateway. Empty string means the spoke has none; subnets with useNatGateway set are then left without one.')
param natGatewayName string = ''

@description('''Set subnets private (defaultOutboundAccess = false), removing Azure's
implicit outbound internet path. Azure is retiring default outbound access for
VNets created with API versions after 31 March 2026, so setting this makes the
behaviour explicit rather than dependent on which API version the template
happens to use.''')
param privateSubnets bool = true

var vnetName = 'vnet-${spokeName}'

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
  }
}

resource nsgs 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = [
  for subnet in subnets: {
    name: subnet.nsgName
  }
]

resource routeTable 'Microsoft.Network/routeTables@2024-01-01' existing = if (!empty(routeTableName)) {
  name: routeTableName
}

resource natGateway 'Microsoft.Network/natGateways@2024-01-01' existing = if (!empty(natGatewayName)) {
  name: natGatewayName
}

// batchSize(1) forces serial deployment: Azure locks the VNet during each
// subnet write and rejects parallel subnet operations on the same VNet.
@batchSize(1)
resource snets 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = [
  for (subnet, i) in subnets: {
    parent: vnet
    name: 'snet-${spokeName}-${subnet.name}'
    properties: {
      addressPrefix: subnet.prefix
      defaultOutboundAccess: !privateSubnets
      // Only the subnet actually hosting private endpoints has the policy
      // disabled, rather than every subnet in the AVD spoke.
      privateEndpointNetworkPolicies: subnet.hostsPrivateEndpoints ? 'Disabled' : 'Enabled'
      networkSecurityGroup: {
        id: nsgs[i].id
      }
      routeTable: empty(routeTableName) ? null : {
        id: routeTable!.id
      }
      natGateway: (subnet.useNatGateway && !empty(natGatewayName)) ? {
        id: natGateway!.id
      } : null
    }
  }
]

output vnetId string = vnet.id
output vnetName string = vnet.name
