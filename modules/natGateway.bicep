// NAT gateway for outbound internet access
//
// Deployed once per spoke that asks for one. A NAT gateway cannot be
// attached to subnets in more than one VNet, so spokes cannot share one -
// each spoke needing outbound access pays for its own gateway and public
// IP. Attaching additional subnets within the same spoke is free beyond
// data processing, which is why the per-spoke and per-subnet decisions are
// separate.
//
// Why this exists at all: Azure's default outbound access is being retired.
// VNets created with API versions released after 31 March 2026 default
// their subnets to private, with no implicit internet path. AVD session
// hosts need outbound access to reach the service, so a spoke hosting them
// needs either this or a route to a firewall that provides egress.
//
// Do not combine this with a route table sending 0.0.0.0/0 to a firewall on
// the same subnet: the user-defined route wins and the NAT gateway bills
// for nothing.

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

param location string
param natGatewayName string

@description('Name for the NAT gateway\'s public IP.')
param publicIpName string

@description('Idle timeout in minutes for outbound flows. Azure default is 4.')
@minValue(4)
@maxValue(120)
param idleTimeoutInMinutes int = 4

@description('Availability zone for the NAT gateway and its public IP. Empty deploys them as regional (non-zonal). A zonal NAT gateway only serves resources in that zone.')
param zone string = ''

var zones = empty(zone) ? [] : [zone]

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: publicIpName
  tags: tags
  location: location
  sku: {
    name: 'Standard'
  }
  zones: zones
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-01-01' = {
  name: natGatewayName
  tags: tags
  location: location
  sku: {
    name: 'Standard'
  }
  zones: zones
  properties: {
    idleTimeoutInMinutes: idleTimeoutInMinutes
    publicIpAddresses: [
      {
        id: publicIp.id
      }
    ]
  }
}

output natGatewayId string = natGateway.id
output publicIpId string = publicIp.id
