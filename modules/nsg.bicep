// Network security group
//
// One module handles both flavours, selected by nsgType:
//
//   'avd'   — outbound allow rules for the documented AVD service
//             dependencies. These do NOT restrict outbound traffic: Azure's
//             default AllowInternetOutBound rule still applies, so this is
//             documentation of required destinations, not enforcement.
//             Real egress control needs a firewall or explicit deny rules.
//
//   'empty' — no custom rules. Only Azure's defaults apply. Exists so the
//             subnet has an NSG to attach customer rules to later without
//             redeploying the VNet.

param location string
param nsgName string

@allowed([
  'avd'
  'empty'
])
param nsgType string

var avdRules = [
  {
    name: 'AllowOutbound-WindowsVirtualDesktop'
    properties: {
      description: 'AVD service control plane'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '443'
      sourceAddressPrefix: 'VirtualNetwork'
      destinationAddressPrefix: 'WindowsVirtualDesktop'
      access: 'Allow'
      priority: 100
      direction: 'Outbound'
    }
  }
  {
    name: 'AllowOutbound-AzureFrontDoorFrontend'
    properties: {
      description: 'AVD reverse-connect / gateway'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '443'
      sourceAddressPrefix: 'VirtualNetwork'
      destinationAddressPrefix: 'AzureFrontDoor.Frontend'
      access: 'Allow'
      priority: 110
      direction: 'Outbound'
    }
  }
  {
    name: 'AllowOutbound-AzureMonitor'
    properties: {
      description: 'Agent health monitoring'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '443'
      sourceAddressPrefix: 'VirtualNetwork'
      destinationAddressPrefix: 'AzureMonitor'
      access: 'Allow'
      priority: 120
      direction: 'Outbound'
    }
  }
  {
    name: 'AllowOutbound-AzureCloud'
    properties: {
      description: 'Azure control plane (auth, gallery, etc.)'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '443'
      sourceAddressPrefix: 'VirtualNetwork'
      destinationAddressPrefix: 'AzureCloud'
      access: 'Allow'
      priority: 130
      direction: 'Outbound'
    }
  }
  {
    name: 'AllowOutbound-Storage'
    properties: {
      description: 'Agent updates, image gallery, FSLogix over public endpoint'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '443'
      sourceAddressPrefix: 'VirtualNetwork'
      destinationAddressPrefix: 'Storage'
      access: 'Allow'
      priority: 140
      direction: 'Outbound'
    }
  }
]

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: nsgType == 'avd' ? avdRules : []
  }
}

output nsgId string = nsg.id
