// =============================================================================
// AVD landing zone — v2 parameters
// =============================================================================
// Copy per customer and edit. Real customer files are gitignored.
//
// IDENTITY MODEL: CLOUD-ONLY. FSLogix storage uses Microsoft Entra Kerberos
// with cloud-only identities — no domain controller, no custom VNet DNS, no
// on-premises connectivity. Session hosts must be Entra-joined and running
// Windows 11 24H2+ or Server 2025.
//
// Resource names are DERIVED from the spoke name, not set here:
//   spoke 'avd' with subnet 'hosts' produces
//     rg-avd, vnet-avd, snet-avd-hosts, nsg-avd-hosts, rt-avd
// =============================================================================

using 'main.bicep'

// -----------------------------------------------------------------------------
// CORE
// -----------------------------------------------------------------------------

param location = 'westus'

// -----------------------------------------------------------------------------
// HUB
// -----------------------------------------------------------------------------

param hubRgName = 'rg-hub'
param hubVnetName = 'vnet-hub'
param hubAddressPrefix = '10.0.0.0/16'

// GatewaySubnet — name is fixed by Azure, do not rename.
param gatewaySubnetPrefix = '10.0.0.0/24'

// Hub firewall:
//   'none'      — no NVA subnets, no spoke route tables, peerings do not
//                 allow forwarded traffic
//   'fortigate' — creates the four FortiGate NIC subnets, creates a route
//                 table per spoke pointing at hubFirewallInternalIp, and
//                 enables forwarded traffic on all peerings
param hubFirewallType = 'none'

// Required when hubFirewallType is not 'none'. Must sit inside
// fgtInternalPrefix, at .68 or higher (Azure reserves the first three
// usable addresses in every subnet).
param hubFirewallInternalIp = ''

// FortiGate NIC subnets — only used when hubFirewallType = 'fortigate'.
param fgtExternalPrefix = ''
param fgtInternalPrefix = ''
param fgtHaPrefix = ''
param fgtMgmtPrefix = ''

// Example values for a FortiGate hub:
//   param hubFirewallType       = 'fortigate'
//   param hubFirewallInternalIp = '10.0.32.68'
//   param fgtExternalPrefix     = '10.0.32.0/26'
//   param fgtInternalPrefix     = '10.0.32.64/26'
//   param fgtHaPrefix           = '10.0.32.128/29'
//   param fgtMgmtPrefix         = '10.0.32.160/27'

// AzureBastionSubnet. Name is fixed by Azure and the prefix must be /26 or
// larger — /27 and smaller are rejected. Creates the subnet only; no
// Bastion host is deployed by this template.
param deployBastionSubnet = false
param bastionSubnetPrefix = ''

// -----------------------------------------------------------------------------
// SPOKES
// -----------------------------------------------------------------------------
// Add or remove entries freely. Each spoke gets its own resource group,
// VNet, and (when peerToHub) a peering in each direction.
//
//   name          short name; drives rg-<name>, vnet-<name>, rt-<name>
//   addressPrefix the VNet address space
//   role          'avd'  — session hosts and the storage private endpoint
//                          land here; its subnets get private endpoint
//                          network policies disabled
//                 'none' — ordinary spoke
//                 Exactly one spoke should have role 'avd'.
//   peerToHub     create hub<->spoke peerings
//   natGateway    create a NAT gateway + public IP in this spoke, giving it
//                 outbound internet. A NAT gateway cannot be shared across
//                 VNets, so each spoke needing one pays for its own
//                 (roughly £25-30/month plus data processing).
//                 Not needed when hubFirewallType routes traffic to a
//                 firewall that provides egress — and do not use both on
//                 the same subnet, because the route table wins and the NAT
//                 gateway bills for nothing.

param spokes = [
  {
    name: 'avd'
    addressPrefix: '10.3.0.0/16'
    role: 'avd'
    peerToHub: true
    natGateway: true
  }
  {
    name: 'prod'
    addressPrefix: '10.1.0.0/16'
    role: 'none'
    peerToHub: true
    natGateway: false
  }
]

// -----------------------------------------------------------------------------
// SUBNETS
// -----------------------------------------------------------------------------
// Matched to their spoke by the `spoke` field, which must equal one of the
// spokes[].name values above.
//
//   nsgType 'avd'   — documented AVD outbound allow rules. NOTE: these do
//                     not restrict outbound traffic; Azure's default
//                     AllowInternetOutBound still applies. They document
//                     required destinations, they do not enforce egress.
//           'empty' — no custom rules; an attachment point for customer
//                     rules added later.
//
//   useNatGateway  attach this subnet to its spoke's NAT gateway. Ignored
//                  when the spoke has natGateway = false. Attaching extra
//                  subnets to an existing NAT gateway is free beyond data
//                  processing, so the cost decision is the spoke flag, not
//                  this one. Leave false for subnets that never make
//                  outbound connections, such as private-endpoint-only
//                  subnets.

param subnets = [
  {
    spoke: 'avd'
    name: 'hosts'
    prefix: '10.3.0.0/24'
    nsgType: 'avd'
    useNatGateway: true
  }
  {
    spoke: 'prod'
    name: 'servers'
    prefix: '10.1.0.0/24'
    nsgType: 'empty'
    useNatGateway: false
  }
]

// -----------------------------------------------------------------------------
// OUTBOUND ACCESS
// -----------------------------------------------------------------------------

// true sets spoke subnets private (defaultOutboundAccess = false), removing
// Azure's implicit outbound internet path so connectivity is explicit
// rather than dependent on the template's API version.
//
// WARNING: a private subnet with no NAT gateway and no firewall route has
// NO internet access. The deployment still SUCCEEDS — the failure appears
// later as session hosts that never register. Check the
// spokesWithoutOutbound deployment output before you deploy.
//
// Set false only to keep Azure's legacy implicit outbound behaviour, which
// Microsoft is retiring.
param privateSubnets = true
