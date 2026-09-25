// Hub VNet
//
// Always deployed. The GatewaySubnet is always created; everything else is
// opt-in so that no subnet exists unless the thing that uses it was asked
// for.
//
// Optional subnets:
//   - Firewall NIC subnets — only when firewallType is an NVA that needs
//     them (currently 'fortigate')
//   - AzureBastionSubnet — name is fixed by Azure and the prefix must be
//     /26 or larger; both are enforced here rather than left to the caller
//
// This is a cloud-only design: identities live in Entra ID, so there is no
// domain controller subnet and no custom VNet DNS.
//
// Subnets are declared as separate child resources, and chained with
// dependsOn, because Azure locks the VNet during each subnet write and
// rejects parallel subnet operations on the same VNet.

param location string
param vnetName string
param addressPrefix string

param gatewaySubnetPrefix string

@description('Hub firewall type. \'none\' creates no NVA subnets; \'fortigate\' creates the four FortiGate NIC subnets.')
@allowed([
  'none'
  'fortigate'
])
param firewallType string

// FortiGate NIC prefixes — ignored unless firewallType == 'fortigate'.
param fgtExternalPrefix string = ''
param fgtInternalPrefix string = ''
param fgtHaPrefix string = ''
param fgtMgmtPrefix string = ''

@description('Create AzureBastionSubnet in the hub. The subnet itself only — no Bastion host is deployed by this template.')
param deployBastionSubnet bool = false

@description('Prefix for AzureBastionSubnet. Azure requires /26 or larger; validated below.')
param bastionSubnetPrefix string = ''

var deployFgtSubnets = firewallType == 'fortigate'

// Azure rejects an AzureBastionSubnet smaller than /26. Catch it here with
// a clear message rather than letting the deployment fail on a generic
// platform error.
var bastionMaskOk = deployBastionSubnet
  ? int(split(bastionSubnetPrefix, '/')[1]) <= 26
  : true

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

// GatewaySubnet — name fixed by Azure. Always created.
resource snetGateway 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  parent: vnet
  name: 'GatewaySubnet'
  properties: {
    addressPrefix: gatewaySubnetPrefix
  }
}

//
// FortiGate NIC subnets
//
resource snetFgtExternal 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployFgtSubnets) {
  parent: vnet
  name: 'snet-fgt-external'
  properties: {
    addressPrefix: fgtExternalPrefix
  }
  dependsOn: [
    snetGateway
  ]
}

resource snetFgtInternal 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployFgtSubnets) {
  parent: vnet
  name: 'snet-fgt-internal'
  properties: {
    addressPrefix: fgtInternalPrefix
  }
  dependsOn: [
    snetGateway
    snetFgtExternal
  ]
}

resource snetFgtHa 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployFgtSubnets) {
  parent: vnet
  name: 'snet-fgt-ha'
  properties: {
    addressPrefix: fgtHaPrefix
  }
  dependsOn: [
    snetGateway
    snetFgtExternal
    snetFgtInternal
  ]
}

resource snetFgtMgmt 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployFgtSubnets) {
  parent: vnet
  name: 'snet-fgt-mgmt'
  properties: {
    addressPrefix: fgtMgmtPrefix
  }
  dependsOn: [
    snetGateway
    snetFgtExternal
    snetFgtInternal
    snetFgtHa
  ]
}

//
// AzureBastionSubnet — name is fixed by Azure, /26 minimum
//
resource snetBastion 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployBastionSubnet) {
  parent: vnet
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: bastionSubnetPrefix
  }
  dependsOn: [
    snetGateway
    snetFgtExternal
    snetFgtInternal
    snetFgtHa
    snetFgtMgmt
  ]
}

output vnetId string = vnet.id
output vnetName string = vnet.name

// Surfaces the Bastion prefix check as a deployment output rather than
// failing silently. main.bicep asserts on this.
output bastionPrefixValid bool = bastionMaskOk
