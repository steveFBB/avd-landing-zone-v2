// Hub VNet
//
// Always deployed. The GatewaySubnet is always created; everything else is
// opt-in so that no subnet exists unless the thing that uses it was asked
// for.
//
// Optional subnets:
//   - Firewall NIC subnets - only when firewallType is an NVA that needs
//     them (currently 'fortigate')
//   - AzureBastionSubnet - name is fixed by Azure and the prefix must be
//     /26 or larger; both are enforced here rather than left to the caller
//
// This is a cloud-only design: identities live in Entra ID, so there is no
// domain controller subnet and no custom VNet DNS.
//
// Subnets are declared as separate child resources, and chained with
// dependsOn, because Azure locks the VNet during each subnet write and
// rejects parallel subnet operations on the same VNet.

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

param location string
param vnetName string
param addressPrefix string

param gatewaySubnetPrefix string

@description('''Hub firewall type.
  none          no firewall subnets at all
  fortigate     the four FortiGate NIC subnets, for an appliance you deploy yourself
  azureFirewall AzureFirewallSubnet, plus AzureFirewallManagementSubnet on the Basic tier''')
@allowed([
  'none'
  'fortigate'
  'azureFirewall'
])
param firewallType string

// FortiGate NIC prefixes - ignored unless firewallType == 'fortigate'.
param fgtExternalPrefix string = ''
param fgtInternalPrefix string = ''
param fgtHaPrefix string = ''
param fgtMgmtPrefix string = ''

@description('Names for the four FortiGate NIC subnets, as you want them. Every customer names things differently, so none of these are fixed.')
param fgtExternalSubnetName string = 'snet-fgt-external'
param fgtInternalSubnetName string = 'snet-fgt-internal'
param fgtHaSubnetName string = 'snet-fgt-ha'
param fgtMgmtSubnetName string = 'snet-fgt-mgmt'

@description('''Prefix for AzureFirewallSubnet. The name is fixed by Azure and the
prefix must be /26 or larger. A /26 is enough at any scale - the firewall provisions
extra instances inside it as it scales, and it never needs enlarging.''')
param azureFirewallSubnetPrefix string = ''

@description('''Prefix for AzureFirewallManagementSubnet, /26 or larger.

Only used on the Basic tier, where a management NIC is mandatory rather than optional -
Microsoft separates their management traffic from customer traffic because Basic has
limited capacity. Standard and Premium do not need it.''')
param azureFirewallManagementSubnetPrefix string = ''

@description('Firewall tier. Basic is the only one that requires the management subnet.')
param azureFirewallTier string = 'Standard'

@description('''Subnet for domain controllers and other shared identity infrastructure.
Empty creates nothing.

A hybrid deployment needs it: the landing zone is built first, a domain controller is
added to the hub afterwards, and the session hosts come later still. Without a subnet
waiting for it there is nowhere in the hub for that domain controller to go.''')
param identitySubnetPrefix string = ''

@description('Name of the identity subnet, as you want it. Only used when identitySubnetPrefix is set.')
param identitySubnetName string = 'snet-identity'

@description('Create AzureBastionSubnet in the hub. The subnet itself only - no Bastion host is deployed by this template.')
param deployBastionSubnet bool = false

@description('Prefix for AzureBastionSubnet. Azure requires /26 or larger; validated below.')
param bastionSubnetPrefix string = ''

var deployFgtSubnets = firewallType == 'fortigate'
var deployAzureFirewallSubnet = firewallType == 'azureFirewall'
var deployAzureFirewallMgmtSubnet = deployAzureFirewallSubnet && azureFirewallTier == 'Basic'

// Azure rejects either firewall subnet below /26, the same way it rejects an
// undersized Bastion subnet.
var azureFirewallMaskOk = (deployAzureFirewallSubnet && !empty(azureFirewallSubnetPrefix))
  ? int(split(azureFirewallSubnetPrefix, '/')[1]) <= 26
  : true

var azureFirewallMgmtMaskOk = (deployAzureFirewallMgmtSubnet && !empty(azureFirewallManagementSubnetPrefix))
  ? int(split(azureFirewallManagementSubnetPrefix, '/')[1]) <= 26
  : true

// Azure rejects an AzureBastionSubnet smaller than /26. Catch it here with
// a clear message rather than letting the deployment fail on a generic
// platform error.
var bastionMaskOk = deployBastionSubnet
  ? int(split(bastionSubnetPrefix, '/')[1]) <= 26
  : true

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  tags: tags
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
  }
}

// GatewaySubnet - name fixed by Azure. Always created.
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
  name: fgtExternalSubnetName
  properties: {
    addressPrefix: fgtExternalPrefix
  }
  dependsOn: [
    snetGateway
  ]
}

resource snetFgtInternal 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployFgtSubnets) {
  parent: vnet
  name: fgtInternalSubnetName
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
  name: fgtHaSubnetName
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
  name: fgtMgmtSubnetName
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
// Azure Firewall subnets - names fixed by Azure, /26 minimum
//
resource snetAzureFirewall 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployAzureFirewallSubnet) {
  parent: vnet
  name: 'AzureFirewallSubnet'
  properties: {
    addressPrefix: azureFirewallSubnetPrefix
  }
  dependsOn: [
    snetGateway
    snetFgtExternal
    snetFgtInternal
    snetFgtHa
    snetFgtMgmt
  ]
}

resource snetAzureFirewallMgmt 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (deployAzureFirewallMgmtSubnet) {
  parent: vnet
  name: 'AzureFirewallManagementSubnet'
  properties: {
    addressPrefix: azureFirewallManagementSubnetPrefix
  }
  dependsOn: [
    snetGateway
    snetFgtExternal
    snetFgtInternal
    snetFgtHa
    snetFgtMgmt
    snetAzureFirewall
  ]
}

//
// AzureBastionSubnet - name is fixed by Azure, /26 minimum
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
    snetAzureFirewall
    snetAzureFirewallMgmt
  ]
}

//
// Identity subnet - for domain controllers added after the landing zone.
//
// Last in the chain for the same reason as the others: Azure locks the VNet
// during a subnet write and rejects parallel operations against it.
resource snetIdentity 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = if (!empty(identitySubnetPrefix)) {
  parent: vnet
  name: identitySubnetName
  properties: {
    addressPrefix: identitySubnetPrefix
    // A domain controller needs to reach Entra Connect and Windows Update, so
    // this subnet keeps default outbound access rather than being private.
    defaultOutboundAccess: true
  }
  dependsOn: [
    snetGateway
    snetFgtExternal
    snetFgtInternal
    snetFgtHa
    snetFgtMgmt
    snetAzureFirewall
    snetAzureFirewallMgmt
    snetBastion
  ]
}

output vnetId string = vnet.id
output vnetName string = vnet.name

@description('Resource ID of the identity subnet. Empty when none was created.')
output identitySubnetId string = empty(identitySubnetPrefix) ? '' : snetIdentity!.id

// Surfaces the Bastion prefix check as a deployment output rather than
// failing silently. main.bicep asserts on this.
output bastionPrefixValid bool = bastionMaskOk

@description('False when AzureFirewallSubnet is smaller than /26, which Azure rejects.')
output azureFirewallPrefixValid bool = azureFirewallMaskOk

@description('False when AzureFirewallManagementSubnet is smaller than /26. Only meaningful on the Basic tier.')
output azureFirewallMgmtPrefixValid bool = azureFirewallMgmtMaskOk
