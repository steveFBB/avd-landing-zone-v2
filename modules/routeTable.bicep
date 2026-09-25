// Route table forcing traffic through the hub firewall
//
// Deployed once per spoke, only when the hub has a firewall.
//
// The RFC1918 routes matter as much as the default route: without them,
// spoke-to-spoke traffic follows the VNet peering directly and bypasses
// the firewall entirely, which defeats the point of having one.

param location string
param routeTableName string

@description('Internal IP of the hub firewall NVA — the next hop for all routes here.')
param firewallInternalIp string

resource routeTable 'Microsoft.Network/routeTables@2024-01-01' = {
  name: routeTableName
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default-via-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallInternalIp
        }
      }
      {
        name: 'rfc1918-10-via-firewall'
        properties: {
          addressPrefix: '10.0.0.0/8'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallInternalIp
        }
      }
      {
        name: 'rfc1918-172-via-firewall'
        properties: {
          addressPrefix: '172.16.0.0/12'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallInternalIp
        }
      }
      {
        name: 'rfc1918-192-via-firewall'
        properties: {
          addressPrefix: '192.168.0.0/16'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallInternalIp
        }
      }
    ]
  }
}

output routeTableId string = routeTable.id
