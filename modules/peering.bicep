// VNet peering (one direction)
//
// Replaces the six near-identical peering modules in v1. Deployed twice per
// spoke - once at hub scope (hub -> spoke) and once at spoke scope
// (spoke -> hub) - with the local/remote arguments swapped.
//
// The caller passes the remote VNet by resource ID rather than by name, so
// this module needs no knowledge of which resource group the remote VNet
// lives in.

@description('Name of the VNet this peering is created on. Must exist in this module\'s scope.')
param localVnetName string

@description('Resource ID of the VNet being peered to.')
param remoteVnetId string

param peeringName string

@description('Allow traffic forwarded by an NVA (rather than originated by the peered VNet) to cross this peering. Must be true on BOTH directions for hub-firewall routing to work.')
param allowForwardedTraffic bool = false

@description('Offer this VNet\'s gateway to the peer. True on hub->spoke when the hub has a VPN/ER gateway.')
param allowGatewayTransit bool = false

@description('Use the peer\'s gateway. True on spoke->hub when the hub has a VPN/ER gateway.')
param useRemoteGateways bool = false

resource localVnet 'Microsoft.Network/virtualNetworks@2024-01-01' existing = {
  name: localVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01' = {
  parent: localVnet
  name: peeringName
  properties: {
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
  }
}
