# Changelog

Template spec versions are **not** immutable — Microsoft's guidance is that you
can update an existing version for hotfixes or publish a new one, and the
version is just a text string. So day-to-day iteration publishes over `dev`:

```
.\scripts\publish-templatespec.ps1 -Location <region>
```

A numbered version is cut only when there is something worth keeping, and
recorded below. **1.0.0 is reserved for the first release fit to put in front
of a customer**, which this is not yet.

## 0.3 — current

Everything below has been built. Only the first group has been run against
Azure.

**Identity model — new, not yet deployed**

The wizard now opens with an Identity tab, immediately after Basics, carrying the
first decision: `entraOnly` or `hybrid`. Everything else follows from it.

`hybrid` builds the landing zone **without session hosts**. Networks, storage,
monitoring, the host pools, their application groups and the workspace are all
created; the hosts are not, because there is no domain controller for them to join
yet. A domain controller is added afterwards and the hosts are created by whatever
process handles that. The host pool rows are still honoured — the pools exist and
are empty, ready to register hosts against.

| | Entra only | Hybrid |
|---|---|---|
| Session hosts | created and Entra joined | not created |
| Access groups | created by the deployment | existing AD groups, object IDs supplied |
| Storage | AADKERB + `kdc_enable_cloud_group_sids` | AADKERB, no tag |
| Share NTFS | `Set-Acl` with cloud SIDs | skipped — no host to run it from |
| Sign-in rights | VM User/Admin Login RBAC | Active Directory, no RBAC |
| VNet DNS | Azure-provided | domain controllers, per spoke |

The Spokes grid gains a DNS servers column. A hybrid deployment needs it pointing at
the domain controllers once they exist, since Azure-provided DNS cannot resolve an
Active Directory domain. Note that setting it makes those servers responsible for all
resolution from the VNet, privatelink included — they must forward to 168.63.129.16
or the storage account resolves to its public IP and profiles stop mounting.

**Firewall decides whether a hub exists — new, not yet deployed**

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

**Literal names for resource groups, VNets and subnets — new, not yet deployed**

The forced `rg-`, `vnet-` and `snet-<spoke>-` prefixes are gone. The Spokes grid
gains **Resource group name** and **VNet name**; the Subnets grid gains **Subnet
name**. Each is used exactly as typed.

The grids' `name` columns are now keys rather than name fragments — subnets
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
customer-specific value — hard-coding a customer's names is the thing to avoid,
standardising our own is not.

A tick box turns the Entra work on and off, on by default. Under it, collapsed, are
the identity name and resource group, prefilled with the script's defaults, for the
case where the script was run with `-IdentityName` or `-ResourceGroup`. Both can be
ignored.

The prerequisite is unchanged and cannot be removed: the script runs once per
tenant, as Global Administrator, before the first deployment. Granting Graph
application permissions is an admin consent operation, and a portal deployment
carries no Graph token — which is the entire reason this identity exists.

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
  nothing and the counters silently collect no data — the same mistake the
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
