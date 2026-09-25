# AVD Landing Zone (v2)

Loop-based rewrite of the AVD landing zone Bicep template. Where v1 had a fixed
hub and three named spokes, this version takes spokes and subnets as arrays and
loops over them — one spoke or five, same code.

**Status: in progress.** Hub, spokes, NSGs, route tables and peerings are built
and validated. Storage, monitoring and the AVD control plane are not yet ported
from v1.

## Identity model: cloud-only

This template targets **cloud-only identities**. FSLogix storage will use
Microsoft Entra Kerberos, which for cloud-only users needs no domain
controller for authentication or authorisation. There is therefore no DC
subnet, no custom VNet DNS, and no on-premises connectivity in this design.

Two constraints follow from that choice:

- **Session hosts must be Entra-joined**, and must run Windows 11 Enterprise
  or Pro 24H2 or newer, or Windows Server 2025 with current cumulative
  updates. Cloud-only Entra Kerberos does not support older builds — hybrid
  identities are more permissive, but hybrid is out of scope here.
- **MFA must be disabled on the storage account's Entra application.** Not on
  users — on the app registration Azure creates for the storage account. A
  broad "require MFA for all apps" Conditional Access policy will break
  authentication to the share.

A storage account supports only one identity source, so every host pool in a
deployment shares this model.

## What it deploys today

- One hub VNet, always with a GatewaySubnet, plus optional FortiGate NIC
  subnets and AzureBastionSubnet
- Any number of spoke VNets, each in its own resource group
- Any number of subnets, assigned to spokes by name
- An NSG per subnet — either the documented AVD outbound allow rules or an
  empty attachment point
- A route table per spoke when the hub has a firewall, with default and
  RFC1918 routes pointing at it
- An optional NAT gateway and public IP per spoke, for outbound internet
  access where there is no firewall
- Hub-to-spoke and spoke-to-hub peerings for spokes that opt in

## Outbound internet access

Azure is retiring default outbound access. VNets created with API versions
released after **31 March 2026** default their subnets to private, with no
implicit internet path. AVD session hosts need outbound access to reach the
service, so every spoke needs an explicit path.

There are two, and a spoke needs one of them:

- **A hub firewall.** When `hubFirewallType` is not `'none'`, each spoke gets
  a route table sending `0.0.0.0/0` and the RFC1918 ranges to the firewall,
  which provides egress. Nothing further is needed.
- **A NAT gateway.** Set `natGateway: true` on the spoke, then
  `useNatGateway: true` on the subnets that should use it.

The two decisions are separate because the costs are. A NAT gateway cannot be
attached to subnets in more than one VNet, so each spoke needing one pays for
its own gateway and public IP. Attaching further subnets within that spoke is
free beyond data processing.

Do not put a NAT gateway and a firewall route table on the same subnet — the
user-defined route wins and the NAT gateway bills for nothing.

`privateSubnets` (default `true`) sets `defaultOutboundAccess = false` so this
behaviour is explicit rather than dependent on the template's API version.

**A spoke with neither path still deploys successfully.** The failure appears
later, as session hosts that never register. The `spokesWithoutOutbound`
deployment output lists any spoke in that state — check it before deploying.

## Still to port from v1

- FSLogix storage account, file share, private endpoint, private DNS zone
- Log Analytics workspace and diagnostic settings
- AVD control plane (host pool, application group, workspace)

## Naming

Names are derived from the spoke name rather than set individually. A spoke
called `avd` with a subnet called `hosts` produces:

```
rg-avd
vnet-avd
snet-avd-hosts
nsg-avd-hosts
rt-avd              (only when the hub has a firewall)
```

The hub is the exception — `hubRgName` and `hubVnetName` are set explicitly.

## Structure

```
main.bicep                      subscription-scoped entry point
parameters.example.bicepparam   copy per customer
modules/
  hub.bicep                     hub VNet and its optional subnets
  spoke.bicep                   one spoke VNet and its subnets
  peering.bicep                 one peering, used twice per spoke
  nsg.bicep                     AVD or empty NSG
  routeTable.bicep              forced routing through the hub firewall
```

## Defining spokes and subnets

Two arrays. Spokes:

```bicep
param spokes = [
  { name: 'avd',  addressPrefix: '10.3.0.0/16', role: 'avd',  peerToHub: true }
  { name: 'prod', addressPrefix: '10.1.0.0/16', role: 'none', peerToHub: true }
]
```

`role: 'avd'` marks the spoke that will host session hosts and the storage
private endpoint; its subnets get private endpoint network policies disabled.
Exactly one spoke should have it.

Subnets reference their spoke by name:

```bicep
param subnets = [
  { spoke: 'avd',  name: 'hosts',   prefix: '10.3.0.0/24', nsgType: 'avd' }
  { spoke: 'prod', name: 'servers', prefix: '10.1.0.0/24', nsgType: 'empty' }
]
```

Both arrays are flat — every field is a string, number or boolean — so they can
be collected by a portal form grid later without nesting.

## The firewall switch

`hubFirewallType` drives three things at once, so they cannot drift apart:

| | `'none'` | `'fortigate'` |
|---|---|---|
| Hub NVA subnets | not created | four FortiGate NIC subnets |
| Spoke route tables | not created | one per spoke, default + RFC1918 via the firewall |
| Peering forwarded traffic | disabled | enabled in both directions |

The last row matters: without forwarded traffic allowed on both sides of a
peering, spoke-to-spoke traffic forwarded by the firewall is dropped at the
peering rather than reaching its destination.

When `hubFirewallType` is not `'none'`, `hubFirewallInternalIp` is required.

## Deploying

```
az login
az account set --subscription "<subscription>"

az deployment sub what-if --location <region> --template-file main.bicep --parameters parameters.example.bicepparam
```

Swap `what-if` for `create` once the plan looks right.

Expected resource counts:

| Configuration | Resources |
|---|---|
| 1 spoke, 1 subnet, no firewall, NAT gateway | 11 |
| 2 spokes, 2 subnets, no firewall, NAT on the AVD spoke (the example file) | 17 |
| 4 spokes, 5 subnets, FortiGate + Bastion subnet, no NAT | 36 |

A NAT gateway adds two resources per spoke — the gateway and its public IP.

## Validation status

All files compile and lint clean with Bicep CLI 0.47.16. The example parameters
and both edge cases above validate with `bicep build-params`.

Nothing here has been deployed to Azure yet. `what-if` and `build` catch
template errors; they do not catch quota, naming collisions, or policy.

## Known limitations

- Greenfield only. Creates its own resource groups and VNets; does not consume
  existing hub, DNS or Log Analytics infrastructure.
- Cloud-only identities only. Hybrid environments needing AD DS Kerberos, a
  domain controller, custom VNet DNS or on-premises connectivity are not
  supported by this design.
- FortiGate is the only NVA layout offered. Azure Firewall would need a
  fixed-name `AzureFirewallSubnet` and is not implemented.
- The AVD NSG rules document required outbound destinations; they do not
  restrict egress. Azure's default `AllowInternetOutBound` still applies.
- Empty NSGs are attachment points, not segmentation.
- The Bastion `/26` minimum is surfaced as the `bastionPrefixValid` output
  rather than failing the deployment. Check it if the subnet is rejected.
- A spoke with no outbound path deploys successfully and fails at runtime.
  `spokesWithoutOutbound` flags it, but nothing blocks the deployment —
  Bicep has no non-experimental assertion mechanism.
- NAT gateways are deployed as regional, not zonal. A zonal NAT gateway only
  serves resources in its own zone; the module accepts a `zone` parameter but
  `main.bicep` does not currently expose it.
- Storage, monitoring and the AVD control plane are not yet ported.
