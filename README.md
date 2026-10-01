# AVD Landing Zone (v2)

A reusable AVD landing zone, deployed from a portal wizard through an Azure
Template Spec. Spokes, subnets and host pools are arrays and looped over - one
VNet or five, same code.

It follows Microsoft's own AVD landing zone accelerator on the decisions that
shape everything else: an existing VNet is a first-class choice, a hub is
something you peer into rather than something a workload builds, and the default
egress is a NAT gateway rather than a firewall. It will still **create** a hub,
with a firewall, when you ask it to - for a greenfield customer where nobody
else is going to. See [Network](#network).

Every publish stamps a build number into the template spec, so you can always
tell which code is in Azure:

```powershell
az ts show --name avd-landing-zone --version dev `
  --resource-group rg-templatespecs --query description -o tsv
```

Day-to-day iteration publishes over `dev`. Numbered versions are cut only for
milestones, and 1.0.0 is reserved for the first release fit for a customer. See
[CHANGELOG.md](CHANGELOG.md).

**Status: in development, not customer-ready.** The cloud-only path has been
deployed end to end and FSLogix profiles mount. The hybrid path, the
existing-network path and several recent changes have never been deployed. See
[Validation status](#validation-status).

## Identity model

Chosen on the Identity tab, and almost everything else follows from it.

| | `entraOnly` | `hybrid` |
|---|---|---|
| Session hosts | created, Entra joined | **not created** |
| Access groups | created, or object IDs supplied | either |
| Storage | AADKERB + `kdc_enable_cloud_group_sids` | AADKERB, no tag |
| Share NTFS | set automatically via `Set-Acl` | manual, with `icacls` |
| Sign-in rights | VM User / Administrator Login | Active Directory |

**`hybrid` builds the landing zone without session hosts.** It is for a
customer whose domain controller does not exist yet: networks, storage,
monitoring, host pools, application groups, workspace and groups are all
created, the pools are left empty, and the hosts are created later by whatever
process handles that once a domain controller is in place. This template never
creates session hosts under hybrid.

The choice is `identityModel`. Entra Kerberos is deferred under hybrid until
`hybridDomainControllerReady` is set - the tick box saying the domain controller
exists and Entra Connect is syncing. Until then the storage account
is created without AADKERB and no admin consent is granted - both need
identities that are already synced, so enabling them on a first pass would
configure something that cannot work. `entraKerberosDeferred` reports it.

The sequence for a hybrid customer:

1. Deploy the landing zone.
2. Build the domain controller and get Entra Connect syncing.
3. Set `dnsServers` on the Identity tab to those domain controllers. Every VNet
   this template creates uses them, and they must forward to 168.63.129.16 or the
   storage account resolves to its public IP and profiles stop mounting.
4. Redeploy with the domain controller box ticked.
5. Create the session hosts and register them against the empty host pools.

### Cloud-only constraints

> **Microsoft Entra Kerberos with cloud-only identities is documented as
> Preview**, and supported in Azure Public only - not US Gov, not China.
> Hybrid identities with Entra Kerberos are generally available. That matters
> commercially as much as technically, so raise it before committing.

- **Session hosts must be Entra joined**, and must run Windows 11 24H2 or later
  **at or above Microsoft's documented minimum cumulative update**. The version
  alone is not enough:

  | Version | Minimum KB | Minimum build |
  |---|---|---|
  | Windows 11 24H2 | KB5079391 | 26100.8116 |
  | Windows 11 25H2 | KB5079391 | 26200.8116 |
  | Windows 11 26H1 | KB5079489 | 28000.1764 |
  | Windows Server 2025 | latest cumulative update | - |

  A freshly deployed marketplace image does **not** necessarily meet this, and
  the template sets `enableAutomaticUpdates: false` with `patchMode: Manual`
  deliberately. Check the build on a new host before concluding FSLogix is
  broken.
- **MFA must be disabled on the storage account's Entra application.** Not on
  users - on the app registration Azure creates for the storage account. A
  broad "require MFA for all apps" policy breaks authentication to the share.
- **Both `WinHttpAutoProxySvc` and `iphlpsvc` must be running.** The template
  attempts this on each host, best effort: `Set-Service` on the first is
  refused even as SYSTEM, so it falls back to the registry, and failure there
  is logged rather than fatal.

A storage account supports one identity source, so every host pool in a
deployment shares this model.

## What it deploys

**Network** - only when `networkMode` is `create`

- Any number of VNets, each in its own resource group, named as you type them
- Any number of subnets, assigned to their VNet by key
- An NSG per subnet - either a set of informational service-tag rules for AVD,
  or an empty attachment point
- A NAT gateway and public IP per VNet that asks for one
- A route table per VNet when routing through an existing firewall
- Peerings to an existing hub VNet, for VNets that opt in

No hub is created. See [Network](#network).

**Storage**

- An FSLogix storage account and SMB share, with a private endpoint and a
  privatelink DNS zone linked to every VNet that has to resolve the share
- Microsoft Entra Kerberos enabled on the account, with admin consent granted
  and the cloud-group-SIDs tag applied to its Entra application
- Azure RBAC on the share for the AVD user and admin groups
- NTFS permissions on the share root, set from the first session host

**Monitoring**

- A Log Analytics workspace, with diagnostics from every VNet, the storage
  account and every AVD control plane resource
- Azure Monitor Agent on each session host, with a data collection rule
  carrying Microsoft's AVD Insights counter and event set including both
  FSLogix channels
- An action group and six alerts: session host availability, connection failure
  rate, FSLogix errors, disk space, CPU and memory

**AVD**

- Any number of pooled host pools, each with its own desktop application
  group, all surfaced through a single workspace
- Session hosts per host pool, built from a gallery image, Entra joined,
  optionally enrolled in Intune, and registered with their host pool.
  `entraOnly` only.
- The Desktop Virtualization User role on each application group, and Virtual
  Machine User Login on the session hosts, so desktops are both visible and
  usable without a manual step

**Entra ID**

- The AVD users and admins groups, created if you want them created

**Everywhere**

- Tags on every resource that supports them, and on the resource groups. One set,
  applied everywhere: `tagPairs` is the array the wizard's grid produces, merged
  with the `tags` object a parameters file can set. There is no per-resource-group
  tagging.
  Subnets, peerings, role assignments, diagnostic settings and data collection
  rule associations do not take tags - an Azure limitation, so coverage is
  never quite complete.
- A session host time zone, and separately time zone redirection so each
  session adopts the time zone of the client connecting to it. Different
  mechanisms; they combine.

## Before you deploy: the Entra bootstrap

Creating Entra groups and finishing the Entra Kerberos setup are Microsoft
Graph operations. The Azure portal's deployment flow carries no Graph token, so
a template deployed from a Create blade cannot do either by itself - the
Microsoft Graph Bicep extension is GA but documented to fail with 401 inside a
Template Spec, and portal deployments fail with "Insufficient privileges to
complete the operation".

The way round it is a deployment script running as a **user-assigned managed
identity**, which does carry an app-only Graph token. That identity is created
once per tenant:

```
.\scripts\bootstrap-entra-identity.ps1 -Location northeurope
```

**Nothing needs copying afterwards.** `useEntraManagedIdentity` is on by
default and the template finds the identity by the name and resource group the
script gives it - `id-avd-entra-ops` in
`rg-identity` - so there is nothing to paste into the wizard. Override
`entraManagedIdentityName` or `entraManagedIdentityRgName` in a parameters file
on the rare occasion the script was run with `-IdentityName` or
`-ResourceGroup`.

What it grants, and why each one:

| Permission | Needed for |
|---|---|
| `Group.ReadWrite.All` | Creating the access groups, and reading first so redeployment does not create duplicates |
| `Application.ReadWrite.All` | Adding the `kdc_enable_cloud_group_sids` tag to the storage account's application |
| `DelegatedPermissionGrant.ReadWrite.All` | Granting admin consent on that application |
| `Reader` (Azure RBAC, subscription) | Not for the work itself - the script container runs `az login --identity` before your script, and that fails when the identity can see no subscription |

These are tenant-wide permissions. Read them before running the script.

**Who can run it:** granting Microsoft Graph app roles specifically requires
Global Administrator or Privileged Role Administrator. Application
Administrator is not enough, which catches people out.

**Who can then deploy:** whoever runs the deployment needs **Managed Identity
Operator** on that identity, as well as their usual rights. Contributor or
Owner on its resource group both include it.

Not running it at all is supported: untick **Use the bootstrap managed
identity**. The rest of the template deploys normally, group object IDs are
taken as parameters instead, and the Entra work becomes four manual steps. The
`entraWorkSkippedNoIdentity` output says so.

## Network

A hub carries the customer's gateway, their firewall and - in a hybrid
environment - their domain controllers. It belongs to whoever runs their
network, and in Microsoft's enterprise-scale model it lives in a connectivity
subscription owned by the platform team. Microsoft's own AVD accelerator never
creates one; it peers into whatever exists.

This template defaults to that, and will still build a hub when you choose to.
The difference matters: creating one makes you the owner of part of the
customer's network design. Right for a greenfield site where nobody else will
build it, questionable where they already have Azure.

The decision is `hubMode`, and it only applies when creating VNets:

| | |
|---|---|
| `none` | No hub. The VNets stand on their own, with no peerings and nothing joining them. |
| `create` | Built here: gateway subnet, optionally a firewall, an identity subnet for domain controllers, and a Bastion subnet. |
| `existing` | Peer to one that already exists, named by `peerToExistingHubVnetId`. |

### Create or use existing VNets

`networkMode` is the first question on the Network tab.

**`create`** builds the VNets from the Spokes and Subnets tabs, as before.

**`existing`** creates nothing network-shaped. You supply:

| | |
|---|---|
| `existingSessionHostSubnetId` | Where the session hosts go |
| `existingPrivateEndpointSubnetId` | Where the FSLogix private endpoint goes. May be the same subnet. Empty skips the private endpoint. |
| `avdResourceGroupName` | Created, for the host pool, application group, workspace and session hosts |

The privatelink DNS zone is linked to whichever VNets those subnets belong to,
deduplicated - both are often in the same one, and two zone links with the same
name fail the deployment.

### Peering

Every VNet with `peerToHub: true` is peered to the hub, in both directions -
whether that hub was built here or already existed.

Both sides of a peering have to exist, and for an existing hub the other side
lives in the customer's own resource group. That is only reachable when the hub
is in the same subscription, since a subscription-scoped template cannot deploy
into another. When it is elsewhere, only the spoke side is created and
`hubSidePeeringNotCreated` says so. **Neither side carries traffic until their
network team adds the matching peering.** A hub built here is always in this
subscription, so both sides are created.

Peerings are created with `allowForwardedTraffic` on both sides. Without it,
traffic the hub's firewall forwards between spokes is dropped at the peering
rather than reaching its destination, and the symptom is a route that silently
fails rather than an error.

### Outbound internet

Azure is retiring default outbound access: VNets created with API versions
after **31 March 2026** default their subnets to private. Session hosts reach
the AVD service over the internet to register, so a host with no egress never
comes up.

`egressMode`:

| | |
|---|---|
| `natGateway` | A NAT gateway per VNet that asks for one. The default. |
| `firewall` | A default route to a firewall that **already exists**, by its private IP. Route tables are created and attached; the firewall is not. |
| `none` | Neither. Correct only when the subnets are not private, or something outside this deployment provides egress. |

**A firewall in a hub you created overrides this.** Set `hubFirewallType` and
every created VNet routes through it - there is no sense in building one and
then routing around it.

**NAT gateway is Microsoft's recommendation for AVD.** Their wording: it
"mitigates performance effects of routing AVD service traffic through
firewalls", and a firewall is "not recommended as the primary egress method"
for AVD. Session hosts talk to the service constantly, and an inspection device
in that path costs you.

A NAT gateway cannot be attached to subnets in more than one VNet, so each VNet
needing one pays for its own gateway and public IP. Set `natGateway: true` on
the VNet **and** `useNatGateway: true` on its subnets - a gateway with no
subnet attached does nothing.

Do not put a NAT gateway and a firewall route table on the same subnet. The
user-defined route wins and the NAT gateway bills for nothing.

**A VNet with no egress path still deploys.** When it is the one carrying
session hosts, they are skipped rather than built into a state where they can
never register: `sessionHostsSkippedNoOutbound` says so.
`spokesWithoutOutbound` lists every VNet in that state.

## Naming

Resource groups, VNets and subnets are named **exactly as you type them** on
the Spokes and Subnets tabs. Leave a name blank and it falls back to the old
derived pattern - `rg-<key>`, `vnet-<key>`, `snet-<key>-<name>` - so a
parameters file written before those columns existed still produces the same
resources.

The `name` column on each grid is a **key**, not a name: subnets reference their
parent VNet by it. Nothing is named from it unless you leave a name blank.

The FortiGate NIC subnets are named by `fgtExternalSubnetName` and its three
siblings. The only subnet names this template cannot let you choose are the ones
Azure fixes: `GatewaySubnet`, `AzureFirewallSubnet`,
`AzureFirewallManagementSubnet` and `AzureBastionSubnet`.

Still derived, because they have no grid row of their own: NSGs
(`nsg-<subnet name>`), route tables (`rt-<key>`), NAT gateways (`nat-<key>`),
host pools (`hp-<name>`), application groups (`ag-<name>-desktop`), the Log
Analytics workspace and the data collection rule.

Session host names come from the host pool name, lowercased, hyphens stripped
and truncated to 11 characters, with an index appended: host pool `desktops`
produces `desktops-0`, `desktops-1` and so on. Windows caps computer names at
15 characters, which is where the 11 comes from. Two pools whose names agree in
their first 11 characters would collide; `duplicateSessionHostPrefixes` flags
that, and `vmNamePrefix` on a pool overrides it.

## Structure

```
main.bicep                      subscription-scoped entry point
parameters.example.bicepparam   copy per customer
uiFormDefinition.json           the portal wizard
modules/
  hub.bicep                     hub VNet and its optional subnets
  azureFirewall.bicep           firewall, policy and AVD egress rules
  spoke.bicep                   one VNet and its subnets
  peering.bicep                 one peering, used twice per peered VNet
  nsg.bicep                     AVD or empty NSG
  routeTable.bicep              default route to an existing firewall
  natGateway.bicep              NAT gateway and its public IP
  storage.bicep                 FSLogix account, share, Entra Kerberos
  storageRbac.bicep             share-level role assignments
  storageEntraKerberos.bicep    admin consent and the cloud group SIDs tag
  fslogixPrivateAccess.bicep    DNS zone, VNet links, private endpoint
  fslogixNtfsPermissions.bicep  NTFS on the share root, via Run Command
  logAnalytics.bicep            workspace
  vnetDiagnostics.bicep         per-VNet diagnostic settings
  storageDiagnostics.bicep      storage diagnostic settings
  avdInsightsDcr.bicep          AVD Insights data collection rule
  alerts.bicep                  action group and the starter alert set
  avdDesktopName.bicep          renames the published desktop
  avdHostPool.bicep             host pool and its registration token
  avdApplicationGroup.bicep     desktop app group and its user assignment
  avdWorkspace.bicep            the single workspace
  sessionHost.bicep             VMs, Entra join, AVD agent registration
  sessionHostLogin.bicep        Virtual Machine User / Administrator Login
  entraGroups.bicep             the AVD access groups
scripts/
  bootstrap-entra-identity.ps1  one-time per-tenant Graph identity
  publish-templatespec.ps1      publish the template and its wizard
```

## Defining spokes and subnets

Two arrays. Spokes:

```bicep
param spokes = [
  { name: 'avd',  rgName: 'rg-avd',  vnetName: 'vnet-avd',  addressPrefix: '10.3.0.0/16', role: 'avd',  peerToHub: true, natGateway: true }
  { name: 'prod', rgName: 'rg-prod', vnetName: 'vnet-prod', addressPrefix: '10.1.0.0/16', role: 'none', peerToHub: true, natGateway: false }
]
```

`name` is the key subnets are matched on. `rgName` and `vnetName` are the real
resource names; leave them out and they fall back to `rg-<name>` and
`vnet-<name>`.

`role: 'avd'` marks the VNet that will host session hosts and the storage
private endpoint; its subnets get private endpoint network policies disabled.
Exactly one should have it. Ignored when `networkMode` is `existing`, where the
subnets are named directly.

Subnets reference their spoke by name:

```bicep
param subnets = [
  { spoke: 'avd',  name: 'snet-desktops', prefix: '10.3.0.0/24', nsgType: 'avd',   useNatGateway: true,  hostsPrivateEndpoints: true }
  { spoke: 'prod', name: 'snet-servers',  prefix: '10.1.0.0/24', nsgType: 'empty', useNatGateway: false, hostsPrivateEndpoints: false }
]
```

Here `name` **is** the subnet's name, used as typed. Its NSG is called
`nsg-<that name>`.

Both arrays are flat - every field is a string, number or boolean - so the
portal form can collect them in a grid without nesting.

Session hosts land in the AVD spoke's first subnet with `nsgType: 'avd'`. That
is not arbitrary: the AVD rule set exists to document the outbound destinations
session hosts need, so a subnet carrying it is by definition the session host
subnet. If there is no such subnet they are skipped, and
`sessionHostsSkippedNoSubnet` says so.

## Firewalls

Two ways to have one, and one way not to.

**A firewall that already exists.** Set `egressMode` to `firewall` and give
`firewallPrivateIp`. Each created VNet gets a route table sending `0.0.0.0/0`
and the RFC1918 ranges to it. Nothing is deployed.

**A firewall in a hub built here.** Set `hubMode` to `create` and
`hubFirewallType`:

| | `azureFirewall` | `fortigate` |
|---|---|---|
| Hub subnets | `AzureFirewallSubnet`, plus `AzureFirewallManagementSubnet` on Basic | four FortiGate NIC subnets, named by you |
| The appliance | deployed, with an AVD egress policy | yours to deploy |
| IP for the routes | read from the resource | `hubFirewallInternalIp`, by hand |

Reading the IP from the resource removes a whole class of transcription error,
which is the main reason to prefer Azure Firewall where there is a choice.

### The Azure Firewall policy

It carries Microsoft's documented AVD egress rules, so session hosts work
through it without further configuration: the `WindowsVirtualDesktop` FQDN tag,
service tags for the control plane and platform, RDP Shortpath STUN on UDP
3478, Windows activation on 1688, the Entra join and sign-in endpoints, the
certificate endpoints, and the Azure Monitor Agent control endpoints.

Three are worth knowing about, because each fails quietly if omitted:

- **Six certificate endpoints are HTTP on port 80**, not HTTPS. An HTTPS-only
  rule set breaks attestation certificate provisioning.
- **`pas.windows.net` is not in the AVD required-URL list** and is not reliably
  covered by the `AzureActiveDirectory` service tag. Without it the host joins
  Entra ID and then nobody can sign in to it.
- **Windows activation uses a service tag, not a hostname.** FQDN filtering in
  a network rule needs DNS proxy and is unavailable on Basic, and port 1688
  cannot go in an application rule at all since those are HTTP and HTTPS only.

Ordering is handled: the firewall depends on its rule collection group, and the
route tables depend on the firewall. Session hosts Entra join at first boot, and
a default route pointing at a firewall with no rules yet fails that join
silently.

**The Basic tier is not a cheaper Standard.** It requires a management NIC in
its own `AzureFirewallManagementSubnet` with a second public IP - unconditional,
not a forced-tunnelling option - and tops out at 250 Mbps, which is a real
ceiling for a pooled estate.

Stopping and starting a firewall can change its private IP. If you deallocate
one to save money, redeploy afterwards so the routes are refreshed.

**Microsoft still recommends a NAT gateway for AVD egress**, whichever of these
you build. A firewall is for inspecting traffic you care about, not for getting
session hosts to the AVD service.

## Session hosts

Hosts are built per host pool from the `sessionHostCount` and `vmSize` fields
on each `hostPools` entry. Everything else - image, disk type, local admin
account - is shared by every pool, because in practice one customer runs one
image.

Each host gets three things in a fixed order:

1. **The VM**, from a marketplace gallery image, with Trusted Launch enabled
   and `licenseType: 'Windows_Client'` so the multi-session benefit applies.
2. **`AADLoginForWindows`**, the Entra join extension, optionally carrying
   Intune's application ID for automatic enrolment.
3. **The AVD agent**, via the DSC extension, with `aadJoin: true` and a
   registration token read straight from the host pool.

Step 3 depends on step 2 and that is not decoration. If the agent installs
before the Entra join completes, it registers the host as domain-joined and
sign-in fails with nothing obviously wrong in the AVD blade.

### Images

| | publisher | offer | SKU |
|---|---|---|---|
| Multi-session + Microsoft 365 Apps | `microsoftwindowsdesktop` | `office-365` | `win11-25h2-avd-m365` |
| Multi-session, no Office | `microsoftwindowsdesktop` | `windows-11` | `win11-25h2-avd` |

The Microsoft 365 images are published under the **`office-365` offer**, not
under `windows-11`. This catches people out regularly. The portal wizard offers
a single image dropdown and works the offer out from the SKU; in the parameters
file you have to set both.

All the multi-session images ship FSLogix preinstalled. The binaries, not the
configuration - profile container settings are still yours to apply.

Only 24H2 and newer are offered, and `sessionHostImageSku` is constrained to
them. Cloud-only Entra Kerberos does not support older builds, so a 23H2 host
deploys perfectly and then cannot mount a profile - better to fail validation.

### The DSC artifact URL

`sessionHostArtifactsLocation` points at Microsoft's AVD agent package:

```
https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02797.442.zip
```

Microsoft version-stamps this file, publishes no "latest" alias, and does not
document the current version anywhere. If session host registration starts
failing, that is the first thing to check. The current value is visible in the
template the portal generates from **Host pools -> Add virtual machines ->
Review + create -> Download a template for automation**.

### Registration tokens

The session host module reads the token directly from the host pool with
`listRegistrationTokens()` and puts it in the DSC extension's protected
settings. It never passes through a module output, and it is never a deployment
output - deployment history persists indefinitely, and a registration token is
a credential.

To add hosts outside this template:

```
az desktopvirtualization hostpool retrieve-registration-token --resource-group rg-avd --host-pool-name hp-desktops
```

Redeploying rotates every host pool's token, because the token is declared on
the host pool resource itself.

## FSLogix share readiness

The template now does almost all of this. With a managed identity supplied it
creates the account, share, private endpoint and DNS zone, enables Entra
Kerberos, grants admin consent on the resulting Entra application, tags that
application for cloud-only group SIDs, assigns Azure RBAC on the share, and
sets NTFS permissions on the share root from the first session host.

FSLogix itself is configured on each session host too: the profile container
registry values and `CloudKerberosTicketRetrievalEnabled`, which the host needs
before it will even request a cloud Kerberos ticket. The gallery images ship
FSLogix installed but not configured, so without that step a freshly built host
quietly keeps local profiles.

**One step remains manual, and it always will:**

> Exclude the application named
> `[Storage Account] <account>.file.core.windows.net` from any Conditional
> Access policy that requires MFA.

Entra Kerberos does not support MFA. A broad "require MFA for all apps" policy
produces `System error 1327: Account restrictions are preventing this user from
signing in` when a user tries to load their profile. The application's client
ID is in the `storageEntraApplicationId` deployment output. This is a security
policy change and is deliberately not automated.

### The NTFS permission set

Microsoft's documented set for profile containers:

| Principal | Rights | Applies to |
|---|---|---|
| AVD users group | Modify | This folder only |
| `CREATOR OWNER` | Modify | Subfolders and files only |
| `BUILTIN\Administrators` | Full control | This folder, subfolders and files |

"This folder only" for users is the important row. It lets a user create their
own profile folder and stops them opening anyone else's.

Getting there needs a removal as well as three grants. The default ACL on a new
Azure file share root is **explicit, not inherited** - a share root has no
parent directory - so `icacls /inheritance:r` removes nothing and still exits
0. The entry that matters is `NT AUTHORITY\Authenticated Users:(OI)(CI)(M)`,
which has to be deleted by name or every user keeps Modify on every other
user's profile while the script reports success. Principals are referenced by
SID rather than name, because an Entra-joined host may not resolve the built-in
names reliably this early in its life.

Cloud-only Entra groups have no on-premises SID, so the group's object ID is
converted to its Entra SID form (`S-1-12-1-...`) on the host and passed to
`icacls` as a literal SID, rather than relying on name resolution the host may
not have yet.

The share is mounted with the **storage account key**, which is the only
credential that bypasses NTFS - exactly what you need to set initial
permissions on a share nobody can reach. It also means the step does not depend
on Entra Kerberos having finished.

The trade is that the step needs `storageAllowSharedKeyAccess` true and a
reachable file endpoint - either the private one or `storagePublicNetworkAccess`
still `Enabled`. If either is missing the step is skipped rather than attempted,
and `fslogixNtfsPermissionsSkipped` reports it. Set the permissions, confirm a
client can mount, and only then close the public path.

## Storage hardening

The FSLogix storage account is deployed in a **bootstrap posture**, not its
finished state:

| | Bootstrap | Steady state |
|---|---|---|
| `storageAllowSharedKeyAccess` | `true` | `false` |
| `storagePublicNetworkAccess` | `Enabled` | `Disabled` |

Both are needed during deployment. The control plane creates the file share
over the public endpoint, and the NTFS permissions step mounts the share with
the account key - which is the only credential that bypasses NTFS, and
therefore the only way to set the initial permissions on a share nobody can yet
reach.

Neither should survive into production. Once a client has mounted the share
successfully over the private endpoint, redeploy with both tightened.

The `storageHardeningRequired` output is `true` while either is still in its
bootstrap value. It exists because the alternative is someone seeing a green
deployment, ticks all the way down, and never coming back.

## Deploying

**Deployment is through the template spec and its portal wizard.** That is the
point of the project - a form anyone can fill in, not a parameters file only
its author understands. The command line is for validating changes before
publishing them, not for deploying.

```
az login
az account set --subscription "<subscription>"

.\scripts\publish-templatespec.ps1 -Location northeurope -Version 1.3.0
```

Then **Template specs** -> **avd-landing-zone** -> the version -> **Deploy**.

Template spec versions are immutable, so every change means a new version. Bump
`-Version` each time.

### Validating before publishing

The parameters file exists so template changes can be checked without
publishing a version to find out. It is also the reference for what every
setting means, and what a pipeline would use.

```
az deployment sub what-if `
  --location northeurope `
  --template-file main.bicep `
  --parameters parameters.example.bicepparam `
  --parameters sessionHostAdminPassword='<value>'
```

The password is supplied on the command line rather than in the file. An empty
one fails template validation before what-if reaches anything useful.

Role assignments whose name derives from a group object ID come back as
**unsupported** rather than analysed, because the groups do not exist until the
deployment script has run and what-if will not guess a resource ID. Five of
them is normal and correct. Deployment scripts themselves appear as opaque
resources - what-if cannot evaluate what they do.

Expected resource counts:

| Configuration | Resources |
|---|---|
| The example file: 2 spokes, NAT, storage, monitoring, 1 pool, 2 hosts | ~55 |
| Same with `deploySessionHosts` false | ~42 |
| Same with `hostPools` empty | ~34 |
| Same with storage and monitoring off too | 17 |

Each session host adds four resources: NIC, VM, Entra join extension and AVD
agent extension. Counts are approximate - what-if sometimes groups
sub-resources differently, and deployment scripts each create a transient
storage account and container instance that are cleaned up afterwards.

## Validation status

All files compile and lint clean with Bicep CLI 0.47.16. The example
parameters validate with `bicep build-params`.

**Deployed and verified against a live tenant:** VNets, subnets, NSGs, NAT
gateway, storage account with private endpoint and DNS, Log Analytics with
diagnostics, host pool, application group and workspace, session hosts with
Entra join and registration, the Entra automation, alerts, and FSLogix profile
containers mounting over Entra Kerberos.

**Never deployed:**

- the `hybrid` identity model
- `networkMode: existing`
- `hubMode: existing` - peering to a hub that already exists
- `egressMode: firewall`
- the FortiGate hub path
- more than one host pool

Previously deployed and expected to still work, but not since the hub was
reworked: `hubMode: create` with Azure Firewall, and the Bastion subnet.

**Known not working:** ten performance counters are in the deployed data
collection rule, pass `Get-Counter` on a host, and never reach the workspace -
the LogicalDisk queue lengths, all four Memory counters and all four
PhysicalDisk counters. AVD Insights wants them and therefore reports the hosts
as unconfigured. Cause unknown.

`what-if` and `build` catch template errors. They do not catch quota, image
availability, tenant policy, or anything a deployment script does at runtime -
and `what-if` cannot evaluate deployment scripts at all.

### Known runtime risks

- **`MicrosoftGraphRequestFailed` when enabling Entra Kerberos.** Caused by a
  tenant-wide app management policy restricting `passwordAddition` or
  `symmetricKeyAddition`, which blocks the Storage resource provider from
  adding its own credential. The fix is an app management policy exception
  assigned to the Storage RP's service principal, app ID
  `a6aa9161-5291-40bb-8c5c-923b567bee3b`. This affects the portal, CLI and
  PowerShell identically - it is not specific to ARM.
- **A half-failed Entra Kerberos enablement does not self-heal.** If the first
  attempt errors part way, the backend provisioning state can be left broken,
  later attempts report success without creating the service principal, and it
  takes a support ticket to clear.
- **Deployment scripts create a transient storage account** with public network
  access. An Azure Policy denying that will block them.

## Monitoring and alerts

### AVD Insights

Insights needs two halves and the template provides both: control plane
diagnostic settings on the host pool, application groups and workspace, which
produce the `WVD*` tables; and session host telemetry, collected by the Azure
Monitor Agent against a data collection rule. There is no workbook to deploy -
Insights is a built-in portal experience that discovers whatever data is there.

Two counters in Microsoft's published list are display names rather than valid
counter specifiers, and copying them verbatim collects nothing while reporting
success:

| As documented | As it must be written |
|---|---|
| `Logical Disk(C:)` | `LogicalDisk(C:)` - no space |
| `Memory(*)` | `Memory` - the object has no instances |

The rule also adds `% Free Space`, which is not in Microsoft's set, because
there is no platform metric for disk free space and the alert needs it.

Per-process input delay is off by default. Its instance count scales with
processes multiplied by sessions, so on a busy multi-session host it is a large
share of ingestion cost for detail you rarely act on.

### Alerts

| Alert | Type | Default |
|---|---|---|
| Session host unhealthy | Log, `WVDAgentHealthStatus` | Any host not `Available`, severity 1 |
| Connection failure rate | Log, `WVDConnections` | Over 10% of more than 20 attempts in an hour |
| FSLogix errors | Log, `Event` | Any error on either FSLogix channel, severity 1 |
| Low disk space | Log, `Perf` | C: below 10% free |
| High CPU | Metric | Above 85% average over 15 minutes |
| Low memory | Metric | Available memory below 10% over 15 minutes |

The metric alerts are scoped to the AVD resource group rather than to named
VMs, so hosts added or rebuilt later are covered with no template change -
which is what a rotating pooled host pool needs.

Three deliberate choices worth knowing:

- **Thresholds are judgement, not documentation.** Microsoft publishes no
  guidance for pooled multi-session. The windows are long on purpose: a
  five-minute CPU window pages you every weekday at nine, because logon storms
  peg CPU for two or three minutes as a matter of course.
- **The FSLogix alert matches on channel and level, not event IDs.** Microsoft
  publishes no FSLogix event ID table; the IDs quoted around the internet are
  community folklore. Once you have a fortnight of real data, read off which
  IDs actually accompany genuine mount failures in your estate and narrow the
  query - it already returns the IDs it saw, to make that easy.
- **`skipQueryValidation` is on.** The `WVD*` tables do not exist until the
  first diagnostic data lands, so validating the queries at deploy time would
  fail every greenfield deployment.

Leaving the email address blank still creates the action group and the rules.
Alerts fire and appear in the portal; nobody is notified. The
`alertsHaveNoRecipient` output says so.

## Tearing down

Deleting the resource groups is not enough. **Delete the session hosts' device
objects from Microsoft Entra ID as well**, or the next deployment fails in the
most misleading way this template has produced.

Entra ID -> Devices -> All devices, and delete the entries matching your
session host names (`desktops-0`, `desktops-1` and so on).

Why it matters: VM names are derived from the host pool name and are therefore
identical on every rebuild. A device object left behind by the previous
deployment still owns that hostname, so the new VM's join is refused with
`error_hostname_duplicate`. The `AADLoginForWindows` extension **reports
success anyway** - the deployment goes green, the session hosts appear in the
host pool, and users get a credential prompt that never accepts a correct
password. `dsregcmd /status` on the host shows `AzureAdJoined : NO`.

Keep the identity and template spec resource groups; everything else goes:

```
az group delete --name rg-avd --yes --no-wait
az group delete --name rg-hub --yes --no-wait      # only if one was created
az group delete --name rg-storage --yes --no-wait
az group delete --name rg-mgmt --yes --no-wait
```

The Entra groups created by the deployment are left alone deliberately - they
may hold membership you want to keep. Delete them by hand if you want a clean
tenant.

## Deployment guards

Outputs that flag configurations which deploy successfully but do not work.
None block the deployment - Bicep has no non-experimental assertion mechanism -
so read them on the deployment's Outputs blade once it finishes.

| Output | Meaning |
|---|---|
| `spokesWithoutOutbound` | VNets with no NAT gateway and no firewall route. Their VMs have no internet. |
| `storageHasNoPrivateEndpoint` | Storage deployed but no subnet was flagged `hostsPrivateEndpoints`, so the share is reachable only over its public endpoint. |
| `resourceGroupNameCollisions` | A spoke named `storage` or `mgmt` produces the same resource group name as the shared storage or monitoring group. |
| `hostPoolsSkippedNoAvdSpoke` | Host pools were defined but no spoke has `role: 'avd'`, so the control plane was skipped entirely. |
| `sessionHostsSkippedNoSubnet` | Session hosts were requested but the AVD spoke has no subnet with `nsgType: 'avd'` to put them in. |
| `duplicateSessionHostPrefixes` | Two host pools produce the same VM name prefix. Set `vmNamePrefix` on one. |
| `entraWorkSkippedNoIdentity` | Entra work was requested but no managed identity was supplied, so groups, consent and the manifest tag were all skipped. |
| `fslogixNtfsPermissionsSkipped` | NTFS permissions could not be set - no session host to run from, or no users group. Until they are, every user can read every other user's profile. |
| `bastionPrefixValid` | `false` when `bastionSubnetPrefix` is smaller than `/26`, which Azure rejects. |
| `azureFirewallPrefixValid` | `false` when `AzureFirewallSubnet` is smaller than `/26`. |
| `azureFirewallMgmtPrefixValid` | `false` when `AzureFirewallManagementSubnet` is smaller than `/26`. Basic tier only. |
| `hybridNoIdentitySubnet` | A hub was created for a hybrid deployment but given no identity subnet, so there is nowhere for a domain controller. |
| `sessionHostsSkippedNoOutbound` | The VNet carrying session hosts has no NAT gateway and no firewall route, so they were not created. They could never have registered. |
| `subnetsWithUnknownSpoke` | A subnet's parent VNet key matches no row on the Spokes tab. The deployment fails partway through without this. |
| `hubSidePeeringNotCreated` | A hub VNet was given but it is in another subscription, so only the spoke side of each peering exists. Neither side carries traffic until their network team adds the other. |
| `entraKerberosDeferred` | Hybrid, and the domain controller is not in place yet, so the storage account has no AADKERB and no consent was granted. The intended first-pass state. |
| `hybridSessionHostsSkipped` | Hybrid, so no session hosts were created. By design. |
| `hybridMissingGroupObjectIds` | Hybrid with no group object IDs supplied and none created, so nobody has access to the desktop or the share. |
| `desktopNamesSkippedNoIdentity` | Desktop names were set on host pool rows but no managed identity was supplied, so they are all still called SessionDesktop. |
| `alertsHaveNoRecipient` | Alerts deployed with no email address. They fire, nobody is told. |
| `insightsSkippedNoWorkspace` | Insights requested but monitoring is off, so the agent was not installed. |
| `storageHardeningRequired` | Storage is still in its bootstrap posture - shared key access on, or the public endpoint open. |

Everything should be empty or false, apart from the three `...Valid` outputs,
which should be true, and the two that report a deliberate hybrid state.

**These are deployment outputs, not what-if output.** What-if reports resource
changes only; outputs are evaluated during a real deployment. They save
troubleshooting time; they are not a pre-flight check.

The rest of the outputs are there to be used rather than checked:

| Output | Use |
|---|---|
| `storageEntraApplicationId` | What to search for when excluding the storage app from MFA Conditional Access. |
| `avdUsersGroupId`, `avdAdminsGroupId` | The groups that were created. |
| `identitySubnetId` | The subnet to build a domain controller into, when a hub was created with one. |
| `hubVnetId`, `createdVnetIds` | What was created, for a follow-on deployment. |
| `azureFirewallPrivateIp`, `azureFirewallPublicIp` | The firewall's addresses. The public one is what traffic egresses from. |
| `storageAccountId`, `logAnalyticsWorkspaceId`, `avdWorkspaceId`, `hostPoolNames`, `sessionHostSubnet` | Resource IDs and names, for whatever runs next. |
| `identityModelUsed`, `networkModeUsed` | What the deployment actually did, which is worth recording. |

## Portal wizard

`uiFormDefinition.json` is what gives the template its Create blade, and it is
the intended way in. The tabs collect the same values the parameters file holds,
with validation, dropdowns and grids instead of hand-edited arrays.

| Tab | What it collects |
|---|---|
| Basics | Subscription, region and tags |
| Identity | Entra only or hybrid, the bootstrap identity, groups, Kerberos, NTFS |
| Network | Create or use existing VNets, the hub, its firewall, and outbound internet |
| Spokes | A grid - one row per VNet. Hidden when using existing VNets. |
| Subnets | A grid - one row per subnet. Hidden when using existing VNets. |
| Storage | FSLogix account and private endpoint, or off |
| Monitoring | Log Analytics, AVD Insights, alerts and the notification email |
| AVD | Host pools, desktop names, workspace, session host image, size, local admin, time zone, FSLogix |

Identity comes second because most of the rest follows from it: under hybrid
the session host section disappears entirely.

Adding a row to the Spokes grid adds a resource group, VNet, peerings and
optionally a NAT gateway. Adding a row to Host pools adds a host pool,
application group, workspace entry and its session hosts. Same arrays as the
parameters file, just collected through a form.

Republish after any change to `main.bicep` **or** the form. A template spec
version bundles both, so a form-only change still needs a new version.

### Editing the form

Test changes in the [Form view sandbox](https://aka.ms/form/sandbox) before
republishing. It renders the JSON live and reports schema errors, which is
considerably faster than publishing and clicking through.

Twenty-four parameters are deliberately not exposed - TLS version, shared key
access, public network access, retention SKU, the DSC artifact URL, the
Entra Kerberos and default share permission switches, and similar. They keep
their defaults from `main.bicep`. Anyone needing to change those should use the
parameters file directly.

## Known limitations

- Does not consume an existing Log Analytics workspace or private DNS zone.
  `networkMode: existing` covers an existing network; the rest is still
  created.
- Under `hybrid`, session hosts are never created and NTFS permissions on the
  share are never set. Both are left to whatever process runs once a domain
  controller exists.
- The Entra work needs a bootstrap identity with tenant-wide Graph
  permissions. There is no way round this from a portal Create blade - the
  Microsoft Graph Bicep extension does not work in one, and Microsoft has an
  open issue with no committed date.
- Excluding the storage application from MFA Conditional Access is always
  manual.
- FortiGate is subnets only - the appliance, its licensing and its HA pairing
  are yours. Azure Firewall is the path deployed end to end.
- A hub is only created in the subscription being deployed into. A customer
  whose hub belongs in a separate connectivity subscription needs
  `hubMode: existing`.
- The AVD NSG rules are **informational service-tag rules, not a complete AVD
  allowlist**. They do not contain everything Microsoft currently documents -
  UDP 3478 and several platform endpoints are absent - and they restrict
  nothing, because Azure's default `AllowInternetOutBound` still applies.
  Real egress control means a firewall, which this template routes to but does
  not deploy.
- Empty NSGs are attachment points, not segmentation.
- A VNet with no outbound path deploys successfully. Session hosts in it are
  skipped rather than built broken, but other VMs there will have no egress.
- NAT gateways are deployed as regional, not zonal.
- Session hosts are not zone-distributed and have no availability set. For a
  pooled deployment that matters less than it would for single-session, but it
  is a gap.
- No scaling plan. Hosts run until you stop them.
- No image pipeline. Hosts come from the marketplace gallery image as-is;
  applications beyond Microsoft 365 Apps are yours to deploy.
- Session host names are deterministic, so a rebuild collides with the Entra
  device objects left by the previous deployment. See Tearing down.
- Share RBAC is granted at the storage account, not the share. A second file
  share on that account would inherit it.
- Adding hosts to an existing pool needs `startIndex` on the session host
  module, which `main.bicep` does not currently expose - raising
  `sessionHostCount` and redeploying rebuilds from index 0 and collides.
- Pooled host pools only. Personal (1:1) host pools are not supported.
- Desktop application groups only. RemoteApp is not implemented.
- Does not deploy Bastion hosts or backup.
