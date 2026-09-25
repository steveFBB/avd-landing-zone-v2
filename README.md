# AVD Landing Zone (v2)

Loop-based rewrite of the AVD landing zone Bicep template. Where v1 had a fixed
hub and three named spokes, this version takes spokes and subnets as arrays and
loops over them — one spoke or five, same code.

**Status: feature complete.** Everything from v1 is ported, plus NAT gateways,
multiple host pools, application group user assignment and control plane
diagnostics. Nothing has been deployed to Azure yet — all validation is
`bicep build`, `lint` and `what-if`.

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
- An FSLogix storage account and SMB share, with a private endpoint in the
  AVD spoke and a privatelink DNS zone linked to the hub and every spoke
- Optional Azure RBAC on the share for AVD user and admin groups
- A Log Analytics workspace, with diagnostics from every VNet, the storage
  account and every AVD control plane resource
- Any number of pooled host pools, each with its own desktop application
  group, all surfaced through a single workspace
- The Desktop Virtualization User role assigned to the AVD users group on
  each application group, so desktops are visible without a manual step

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
| The example file: 2 spokes, NAT on AVD, storage, monitoring, 1 host pool | ~40 |
| Same with `hostPools` empty | ~34 |
| Same with storage and monitoring off too | 17 |

A NAT gateway adds two resources per spoke (gateway and public IP). Storage
adds about nine (account, file service, share, DNS zone, one zone link per
VNet, private endpoint, zone group). Monitoring adds one plus a diagnostic
setting per VNet and two for storage.

Counts are approximate — what-if sometimes groups sub-resources differently.

## Validation status

All files compile and lint clean with Bicep CLI 0.47.16. The example parameters
and both edge cases above validate with `bicep build-params`.

Nothing here has been deployed to Azure yet. `what-if` and `build` catch
template errors; they do not catch quota, naming collisions, or policy.

## FSLogix share readiness

The template creates the storage account, share, private endpoint, DNS zone
and Azure RBAC. **The share is not usable by FSLogix yet.**

Two things remain, neither of which Bicep can do:

1. **Enable Microsoft Entra Kerberos** on the storage account. Azure RBAC
   controls who can reach the share; it does not authenticate SMB.
2. **Set NTFS permissions** on the share root from a client that has mounted
   it. Microsoft publishes the recommended permission set for FSLogix
   profile containers.

Until both are done, session hosts will not mount profiles.

Also remember the cloud-only constraints: Entra-joined session hosts on
Windows 11 24H2+ or Server 2025, and MFA disabled on the storage account's
Entra application.

## Deployment guards

Three outputs flag configurations that deploy successfully but do not work.
None of them block the deployment — Bicep has no non-experimental assertion
mechanism — so check them in the what-if output.

| Output | Meaning |
|---|---|
| `spokesWithoutOutbound` | Spokes with no NAT gateway and no firewall route. Their VMs have no internet. |
| `storageHasNoPrivateEndpoint` | Storage deployed but no subnet was flagged `hostsPrivateEndpoints`, so the share is reachable only over its public endpoint. |
| `resourceGroupNameCollisions` | A spoke named `storage` or `mgmt` produces the same resource group name as the shared storage or monitoring group. |
| `hostPoolsSkippedNoAvdSpoke` | Host pools were defined but no spoke has `role: 'avd'`, so the control plane was skipped entirely. |

All four should be empty or false.

**These are deployment outputs, not what-if output.** What-if reports resource
changes only; outputs are evaluated during a real deployment. So these appear
after you deploy, not before. They save you troubleshooting time, but they are
not a pre-flight check.

## Session hosts

The template does not deploy session hosts — VM size, image, and applications
vary too much per customer. What it gives you is a host pool ready to receive
them.

Fetch a registration token when you deploy hosts:

```
az desktopvirtualization hostpool retrieve-registration-token --resource-group rg-avd --host-pool-name hp-desktops
```

The token is deliberately not a deployment output: deployment history persists
indefinitely, and a registration token is a credential. It expires 30 days
after deployment by default.

Session hosts must be Entra-joined and running Windows 11 24H2 or newer, or
Server 2025 — the cloud-only Entra Kerberos requirement.

## Portal wizard

`uiFormDefinition.json` gives the template a Create blade in the Azure portal,
so you fill in a wizard instead of editing a parameters file.

Publish it as a template spec:

```
.\scripts\publish-templatespec.ps1 -Location northeurope
```

Then in the portal: **Template specs** -> **avd-landing-zone** -> **Deploy**.

The wizard has seven tabs:

| Tab | What it collects |
|---|---|
| Basics | Subscription and region |
| Hub | Hub network, firewall type, optional Bastion subnet |
| Spokes | A grid — one row per spoke |
| Subnets | A grid — one row per subnet, matched to a spoke by name |
| Storage | FSLogix account and private endpoint, or off |
| Monitoring | Log Analytics, or off |
| AVD | A grid of host pools, workspace names, Entra group IDs |

Adding a row to the Spokes grid adds a resource group, VNet, peerings and
optionally a NAT gateway. Adding a row to Host pools adds a host pool,
application group and workspace entry. Same arrays as the parameters file,
just collected through a form.

Republish after any change to `main.bicep` or the form — bump `-Version`
each time, since template spec versions are immutable.

### Editing the form

Test changes in the [Form view sandbox](https://aka.ms/form/sandbox) before
republishing. It renders the JSON live and reports schema errors, which is
considerably faster than publishing and clicking through.

Ten parameters are deliberately not exposed in the wizard — TLS version,
shared key access, public network access, retention SKU and similar. They keep
their defaults from `main.bicep`. Anyone needing to change those should use
the parameters file directly rather than the portal.

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
- Does not deploy session hosts, Bastion, or backup.
- Pooled host pools only. Personal (1:1) host pools are not supported.
- Desktop application groups only. RemoteApp is not implemented.
- Redeploying rotates every host pool's registration token, because the token
  is declared on the host pool resource itself.
