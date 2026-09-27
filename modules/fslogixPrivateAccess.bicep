// Private access to the FSLogix share
//
// Bundles the three things that only make sense together:
//   - the privatelink DNS zone for Azure Files
//   - a link from that zone to every VNet that must resolve the share
//   - the private endpoint itself, with its DNS zone group
//
// All three live in the storage resource group. The private endpoint's NIC
// consumes an address from a subnet in the AVD spoke, which is in a
// different resource group — that is normal; the PE resource itself belongs
// here.
//
// Without the DNS zone group, the endpoint gets a private IP but nothing
// resolves to it, and clients silently fall back to the public endpoint.
// That failure survives a "successful" deployment, which is why the zone
// group is part of this module rather than optional.
//
// The zone name is derived from the environment's storage suffix so this
// also works in sovereign clouds, where the suffix differs.

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

@description('Region for the private endpoint. The DNS zone is always global — that is not a choice Azure offers.')
param location string

@description('Resource ID of the storage account to expose privately.')
param storageAccountId string

@description('Resource ID of the subnet the private endpoint NIC lands in.')
param privateEndpointSubnetId string

param privateEndpointName string

@description('VNets that must resolve the share, as objects: { name, id }. One zone link is created per entry.')
param linkedVnets array

var zoneName = 'privatelink.file.${environment().suffixes.storage}'

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  tags: tags
  location: 'global'
}

resource zoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnet in linkedVnets: {
    parent: zone
    name: 'link-${vnet.name}'
    tags: tags
    location: 'global'
    properties: {
      virtualNetwork: {
        id: vnet.id
      }
      // Always false for privatelink zones — these link VNets for
      // resolution, not for registering the VNets' own records.
      registrationEnabled: false
    }
  }
]

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: privateEndpointName
  tags: tags
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: storageAccountId
          // 'file' targets the file service specifically, not blob/queue/table.
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-file'
        properties: {
          privateDnsZoneId: zone.id
        }
      }
    ]
  }
}

output zoneId string = zone.id
output zoneName string = zone.name
output privateEndpointId string = privateEndpoint.id
