# Changelog

Template spec versions are **not** immutable - Microsoft's guidance is that you
can update an existing version for hotfixes or publish a new one, and the
version is just a text string. So day-to-day iteration publishes over `dev`:

```
.\scripts\publish-templatespec.ps1 -Location <region>
```

A numbered version is cut only when there is something worth keeping, and
recorded below. **1.0.0 is reserved for the first release fit to put in front
of a customer**, which this is not yet.

## 0.3 - current

Everything below has been built. Only the first group has been run against
Azure.

## Fixed

**The Basics tab described a template that no longer exists.** It called every deployment
greenfield hub-and-spoke and said hybrid environments were not supported. Both were true
a week ago. It now says what actually gets built depends on the next two tabs, and that
hybrid builds the landing zone without session hosts.

**The tags grid explains itself.** One row is one tag: Name is the key, Value is the
value, both used exactly as typed, applied to the resource groups and every resource that
supports tags. The grey text in an empty row is an example of the shape, not a value.

A row with a name and no value would have failed the deployment - `pair.value` was read
directly where the name was read safely. Both are safe now, and both are trimmed, so a
stray space does not produce a tag key nobody can match on.

**The FSLogix Run Command aborted before configuring anything.** Setting
`WinHttpAutoProxySvc` to Automatic fails with "Access is denied" even though Run Command
executes as SYSTEM - that service's own security descriptor refuses configuration
changes. The script stopped there, so the FSLogix registry settings and the restart
after them never ran, and the host came up with no profile.

Three changes, because one was not enough:

- The service step now runs **after** the FSLogix configuration. An optional
  prerequisite must never be able to stop the thing it is a prerequisite for.
- When `Set-Service` is refused, the start type is written straight to
  `HKLM\SYSTEM\CurrentControlSet\Services\<service>\Start` instead.
- Every part of it is wrapped so it cannot fail the script. Both services are
  trigger-started, so a host that never manages to set them is usually fine; a host
  with no FSLogix configuration is not.

This was introduced two days ago along with the service prerequisites themselves, and
is a good argument for the rule that best-effort steps go last.

**The AVD Insights data collection rule now deploys next to the host pool**, not with
the rest of the monitoring. The Insights configuration workbook lists the rules in the
host pool's own resource group; one sitting in the monitoring group is invisible to it,
so the blade reports the session hosts as not configured and offers to create a second,
competing rule.

Still open on Insights: ten valid performance counters are in the deployed rule, pass
`Get-Counter` on a host, and never reach the workspace - the LogicalDisk queue lengths,
all four Memory counters and all four PhysicalDisk counters. The three Terminal Services
counters that were also missing are explained and fixed (a wildcard on a single-instance
object); these ten are not. The next successful deployment is the chance to read the
agent's own cached configuration and find out.

## Moving to Microsoft's model

Microsoft's own AVD landing zone accelerator does not create a hub, treats an existing
VNet as a first-class choice, and recommends a NAT gateway over a firewall for AVD
egress. This template did the opposite on all three. It now follows theirs.

**The hub is a choice, not an assumption.** `hubMode` - `none`, `create` or
`existing` - and it only applies when creating VNets. Previously the hub was implied by
the firewall question, which is why that question kept needing special cases bolted onto
it.

Microsoft's accelerator only does `existing`: a hub carries the customer's gateway,
firewall and domain controllers, belongs to whoever runs their network, and an AVD
workload peers into it. That is the default here, and `create` remains for a greenfield
site where nobody else is going to build one. The wizard says as much where you choose.

A created hub gets its gateway subnet, optionally an identity subnet for domain
controllers, a Bastion subnet, and a firewall - Azure Firewall deployed with the
documented AVD egress rules, or the FortiGate NIC subnets with the appliance left to
you. A firewall in a hub built here becomes the egress path for every created VNet,
overriding `egressMode`; there is no sense in building one and routing around it.

**Create or use existing VNets.** The Network tab's first question. `create` works as
before, from the Spokes and Subnets tabs. `existing` takes the session host subnet and
the private endpoint subnet as resource IDs, plus a resource group for the AVD
resources, and creates nothing network-shaped. The privatelink DNS zone is linked to
whichever VNets those subnets belong to, deduplicated, since both are often the same one.

**Peering to an existing hub** replaces building one. Both sides of a peering must
exist, and the hub side can only be created when the hub is in the same subscription -
a subscription-scoped template cannot deploy into another. When it is elsewhere, only
the spoke side is created and `hubSidePeeringNotCreated` says so.

**Egress is its own question**, no longer implied by the firewall choice:

| | |
|---|---|
| `natGateway` | A NAT gateway per VNet that asks for one. The default, and Microsoft's recommendation for AVD. |
| `firewall` | A default route to a firewall that already exists, by its private IP. Route tables are created; the firewall is not. |
| `none` | Neither. |

Microsoft's wording on the first: a NAT gateway "mitigates performance effects of
routing AVD service traffic through firewalls", and a firewall is "not recommended as
the primary egress method" for AVD.

Retired with the hub: `networkTopology`, `hubFirewallType`, and every hub, FortiGate,
Azure Firewall, Bastion and identity-subnet parameter.

**Build numbers**

Every publish overwrites the same `dev` version, so nothing in Azure said which code
was actually there - the cause of at least one afternoon spent debugging a stale
template. `publish-templatespec.ps1` now increments a build number, stamps it into the
template spec's version description with a UTC timestamp and the git commit, and writes
it to `BUILD` at the repository root.

The version stays `dev`. The build number is what identifies the code. It shows on the
template spec's Versions blade, or:

```
az ts show --name avd-landing-zone --version dev --resource-group rg-templatespecs --query description -o tsv
```

A description reading `(uncommitted changes)` means the published template does not
match any commit. The number is only written after a successful publish, so a failed
run does not leave the file ahead of Azure.

**Identity model - new, not yet deployed**

The wizard opens with an Identity tab, immediately after Basics, carrying the first
decision: `entraOnly` or `hybrid`.

`hybrid` is for a customer whose domain controller does not exist yet and will be
built in Azure after the landing zone. So hybrid builds everything **except session
hosts**: networks, storage, monitoring, host pools, application groups, workspace,
groups and RBAC. The pools are created and left empty, ready to register hosts
against once a domain controller is in place. This template never creates session
hosts under hybrid.

Because of that sequencing, hybrid forces a hub whether or not a firewall is
selected - the domain controller has to live somewhere - and the hub gains an
optional **identity subnet** for it, named and sized by you. `hybridNoIdentitySubnet`
reports a hybrid deployment that did not define one, and `identitySubnetId` gives the
subnet to build into.

What the identity model actually drives, and nothing else:

| | Entra only | Hybrid |
|---|---|---|
| Session hosts | created and Entra joined | not created |
| Hub | only with a firewall | always |
| Storage | AADKERB + `kdc_enable_cloud_group_sids` | AADKERB, no tag |
| Share NTFS | `Set-Acl` with cloud SIDs | skipped - no host to run it from |
| Sign-in rights | VM User/Admin Login RBAC | Active Directory, no RBAC |

Everything else is identical either way, **including group creation**. The groups
carry Azure RBAC, and an Entra group holds synced users as happily as cloud-only
ones. The caveat, which only bites once session hosts exist: a group created here is
cloud-only and cannot be managed from on-premises AD, and file-level NTFS permissions
resolve group SIDs from the user's Kerberos ticket - which for a hybrid identity
carries its AD groups' SIDs. For NTFS specifically, a synced AD group is safer.
Share-level access is unaffected.

Entra Kerberos is deferred under hybrid until a new tick box, **the domain
controller exists and Entra Connect is syncing**, is set. Until then the storage
account is created without AADKERB and the admin consent script does not run - both
need identities already synced from Active Directory, and on a first pass there is no
domain controller and no sync, so enabling them would configure something that cannot
work. `entraKerberosDeferred` reports that state, which is the intended first-pass
result rather than a failure.

The sequence for a hybrid customer is therefore:

1. Deploy the landing zone. No session hosts, no Entra Kerberos, hub with an identity
   subnet waiting.
2. Build the domain controller into that subnet and get Entra Connect syncing.
3. Set the spokes' DNS servers to the domain controllers.
4. Redeploy with the domain controller tick box set, which enables Entra Kerberos on
   the storage account and grants the admin consent.
5. Create the session hosts with your usual process and register them against the
   empty host pools.

DNS servers are one field on the Identity tab, not a column on the Spokes grid. Every
VNet the template creates uses them, which matches how customers actually run - one set
of domain controllers for the estate. The field only appears once the domain controller
tick box is set, because on a first pass the controllers do not exist and pointing the
VNets at them breaks resolution for everything, the storage private endpoint included.

Setting DNS servers makes them responsible for all resolution from the VNet, privatelink
included: they must forward to 168.63.129.16 or the storage account resolves to its
public IP and profiles stop mounting. A spoke row can still carry its own `dnsServers`
in a parameters file when one VNet needs different resolvers.

**Network topology is its own choice - new, not yet deployed**

The Hub tab is now the **Network** tab and opens with hub and spoke or standalone.

Standalone creates no hub at all: no hub VNet, no peerings, no route tables and no
firewall. You get exactly the VNets from the Spokes grid, independent of one another.
The firewall question and every hub field only appear under hub and spoke, because a
standalone deployment has no hub to put a firewall in.

Previously the topology was a side-effect of the firewall choice, which meant the only
way to get standalone VNets was to decline a firewall - two unrelated decisions welded
together.

A hybrid standalone deployment has no hub for its domain controllers, so the subnet for
them goes on the Subnets tab instead. `hybridStandaloneNoHub` reports that case.

The Subnets tab asked for two names per subnet - a "key" and a name - when the key's
only job was to name the NSG. Now there is one name, used as typed, and the NSG is
called `nsg-<that name>`. The tab's guidance is rewritten to say what each column is for
rather than describing a derivation that no longer happens, and it no longer claims a
mismatched parent spoke is "silently not created": it fails the deployment partway
through, which is what we saw.

The Spokes tab shows a different grid per topology: standalone drops the "Peer to hub"
column entirely rather than leaving a field that does nothing. Portal grids cannot hide
a single column, so there are two grid definitions and the deployment takes whichever
matches. `peerToHub` is read with safe access in the template, since the standalone grid
does not produce it at all.

The tab's intro text also predated the name columns - it still claimed every resource
name was derived from the spoke identifier, which stopped being true when the resource
group and VNet became things you type.

**Outbound access under standalone.** With no hub there is no firewall route, so every
VNet that needs the internet must carry its own NAT gateway. The template already
detected a spoke with neither, but only as a warning output read after the fact - by
which point the session hosts were built and permanently unable to register, since they
reach the AVD service over the internet to do so.

Session hosts are now skipped when the AVD spoke has no outbound path, and
`sessionHostsSkippedNoOutbound` says why. Not created beats created and broken. The
Spokes tab also warns about it while you are filling the grid in.

**Fixed with it:** the hub-to-spoke peerings were conditional on the spoke's own
`peerToHub` flag and nothing else. A spoke set to peer, in a deployment with no hub,
would have tried to peer with a VNet that was never created. Both peering modules now
require a hub to exist, and `spokesPeeringSkippedNoHub` lists any spoke whose peering
was skipped as a result.

**Firewall decides whether a hub exists - new, not yet deployed**

The Hub tab is now the Firewall tab, and the firewall choice comes first on it.
Selecting none creates no hub at all: no hub resource group, no hub VNet, no route
tables and no peerings. You get exactly the VNets defined on the Spokes tab. The hub
name, address space and gateway subnet only appear once a firewall is selected, and
they now carry defaults so a no-firewall deployment does not demand values it will
never use.

The consequence, reported in the `spokesIsolatedNoHub` output rather than left to be
discovered: with no hub the spokes are independent VNets with nothing joining them.
A host in one cannot reach a host in another. Peer them directly, or select a
firewall, if they need to talk. Each spoke needing outbound internet should have a
NAT gateway.

**Literal names for resource groups, VNets and subnets - new, not yet deployed**

The forced `rg-`, `vnet-` and `snet-<spoke>-` prefixes are gone. The Spokes grid
gains **Resource group name** and **VNet name**; the Subnets grid gains **Subnet
name**. Each is used exactly as typed.

The grids' `name` columns are now keys rather than name fragments - subnets
reference their parent spoke by that key, and nothing is derived from it unless you
leave a name blank, in which case the old pattern still applies. A parameter file
written before these columns existed deploys to exactly the same resource names as
before.

Roughly thirty name-construction sites in `main.bicep` now read from two lookups
built once from the Spokes grid, rather than each stitching a prefix together.

Still derived, and next: NSGs, route tables, NAT gateways, host pools, application
groups, the workspace and the data collection rule. Those have no grid row of their
own, so they need a naming pattern rather than a column each.

**Nothing to enter for the managed identity**

The Identity tab used to want the bootstrap managed identity's full resource ID as
free text, pasted into every deployment. It now asks for nothing: the identity is
located by name, and the name is the one `scripts/bootstrap-entra-identity.ps1`
gives it. That script is ours, so the name is a convention rather than a
customer-specific value - hard-coding a customer's names is the thing to avoid,
standardising our own is not.

A single tick box turns the Entra work on and off, on by default. Nothing else. The
identity name and resource group stay as template parameters with the script's
defaults, off the wizard entirely - prefilled required-looking boxes for a case that
never comes up are worse than no boxes at all. Override them in a parameters file if
the script was ever run with `-IdentityName` or `-ResourceGroup`.

The prerequisite is unchanged and cannot be removed: the script runs once per
tenant, as Global Administrator, before the first deployment. Granting Graph
application permissions is an admin consent operation, and a portal deployment
carries no Graph token - which is the entire reason this identity exists.

**Fixed since the last deployment attempt**

- AVD Insights and the disk-space alert failed on a brand new Log Analytics
  workspace with `InvalidOutputTable`. The `Perf` and `Event` built-in tables
  do not exist until something writes to them, so a data collection rule
  created seconds after the workspace has nothing to bind to. The workspace
  module now declares both tables explicitly, and the DCR and alerts consume
  that output so the dependency is real rather than incidental.
- The session host local administrator username was marked `@secure()`, which
  made ARM drop it from `osProfile` and fail the VM with
  `adminUsername is missing (null)`. Secure parameters are for secrets, and a
  username is not one.
- A subnet whose parent spoke does not match any spoke in the Spokes grid used
  to fail mid-deployment with `ResourceGroupNotFound`, after other resources
  had already been created. The deployment now reports the mismatch up front in
  the `subnetsWithUnknownSpoke` output.
- **FSLogix profile containers never mounted.** `CloudKerberosTicketRetrievalEnabled`
  was written to `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters`.
  That path is repeated widely in community guides and is not read by anything.
  It is a Group Policy setting and the Kerberos Policy CSP maps it to
  `HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters`.
  The symptom was deliberately misleading: the registry read back as `1`, the
  storage account was configured correctly, and every mount failed with
  system error 86, "the specified network password is not correct", because the
  client silently fell back to NTLM. `klist cloud_debug` reporting
  `Cloud Kerberos enabled by policy: 0` is the diagnostic that settles it.
- The three Terminal Services session counters in the AVD Insights data
  collection rule were specified as `\Terminal Services(*)\...`. Terminal
  Services is a single-instance performance object, so the wildcard matches
  nothing and the counters silently collect no data - the same mistake the
  module's own header warns about for `\Memory(*)`. Verified on a session host
  with `Get-Counter`: the `(*)` form fails, the bare form succeeds.
- `WinHttpAutoProxySvc` and `iphlpsvc` are now set to Automatic and started.
  Both are documented prerequisites for Entra Kerberos and must be running, not
  merely installed. On Windows 11 multi-session `WinHttpAutoProxySvc` is
  trigger-start and is frequently stopped, which stalls ticket retrieval rather
  than failing it.

**Deployed and verified**

- Hub and spoke networks, NSGs, route tables, NAT gateway, peerings
- FSLogix storage account with private endpoint and privatelink DNS
- Log Analytics with VNet, storage and control plane diagnostics
- Host pools, application groups, workspace
- Session hosts: gallery image, Entra join, host pool registration, sign-in
  role assignments
- Entra automation: bootstrap identity, group creation, Entra Kerberos admin
  consent and the cloud group SIDs tag
- Action group and six alerts
- FSLogix profile containers mounting from Azure Files over Entra Kerberos,
  with NTFS permissions on the share root applied via `Set-Acl`

**Built, not yet run against Azure**

- Azure Firewall with a policy carrying the documented AVD egress rules
- Published desktop rename, replacing "SessionDesktop"
- Tags, session host time zone and time zone redirection
- OS disk size

**Verified by hand, not yet proven from a clean deployment**

- The cloud Kerberos registry fix and the two service prerequisites. The host
  that produced a working profile was corrected manually; the template carries
  the same change but has not been redeployed from scratch since.

**Known not working**

- AVD Insights reports "Azure Monitor is not configured for session hosts"
  despite the data collection rule deploying cleanly. Not yet investigated.

## 0.2

- Session hosts, Entra ID automation, the Entra ID wizard tab.

## 0.1

- First working landing zone: hub, spokes, storage, monitoring and the AVD
  control plane, deployed end to end from the portal wizard.
