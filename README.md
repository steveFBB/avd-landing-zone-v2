# AVD Landing Zone (v2)

**Repository version: 0.3.** See [CHANGELOG.md](CHANGELOG.md)
for what each version contains. Day-to-day iteration publishes over `dev`;
numbered versions are cut only for milestones, and 1.0.0 is reserved for the
first release fit for a customer.

Loop-based rewrite of the AVD landing zone Bicep template. Where v1 had a fixed
hub and three named spokes, this version takes spokes and subnets as arrays and
loops over them — one spoke or five, same code.

> **This template uses Microsoft Entra Kerberos with cloud-only identities,
> which Microsoft currently documents as Preview.** Hybrid identities with
> Entra Kerberos are generally available; cloud-only is not. Cloud-only is also
> supported in Azure Public only — not US Gov, not China. That matters
> commercially as much as technically, so raise it with a customer before
> committing to this design.

**Status: core infrastructure deployed and verified; session host and Entra
automation pending full live validation.** The networking, storage, monitoring
and control plane layers have been deployed end to end from the portal wizard
with every guard clean. Session hosts, the Entra automation, Azure Firewall,
Insights and the alerts have had `build`, `lint` and `what-if` only — and those
are the riskier halves. See [Validation status](#validation-status).

## Identity model: cloud-only

This template targets **cloud-only identities**. FSLogix storage uses
Microsoft Entra Kerberos, which for cloud-only users needs no domain
controller for authentication or authorisation. There is therefore no DC
subnet, no custom VNet DNS, and no on-premises connectivity in this design.

Two constraints follow from that choice:

- **Session hosts must be Entra-joined**, and must run Windows 11 24H2 or
  later **at or above Microsoft's documented minimum cumulative update**. The
  version alone is not enough:

  | Version | Minimum KB | Minimum build |
  |---|---|---|
  | Windows 11 24H2 | KB5079391 | 26100.8116 |
  | Windows 11 25H2 | KB5079391 | 26200.8116 |
  | Windows 11 26H1 | KB5079489 | 28000.1764 |
  | Windows Server 2025 | latest cumulative update | — |

  A freshly deployed marketplace image does **not** necessarily meet this, and
  the template sets `enableAutomaticUpdates: false` with `patchMode: Manual`
  deliberately — controlled image management, which assumes an image or patch
  pipeline exists elsewhere. This template does not provide one. Check the
  build on a new host before concluding that FSLogix is broken.
- **MFA must be disabled on the storage account's Entra application.** Not on
  users — on the app registration Azure creates for the storage account. A
  broad "require MFA for all apps" Conditional Access policy will break
  authentication to the share.

A storage account supports only one identity source, so every host pool in a
deployment shares this model.

## What it deploys

**Network**

- One hub VNet, always with a GatewaySubnet, plus optional FortiGate NIC
  subnets and AzureBastionSubnet
- Any number of spoke VNets, each in its own resource group
- Any number of subnets, assigned to spokes by name
- An NSG per subnet — either a set of informational service-tag rules for AVD,
  or an empty attachment point
- A route table per spoke when the hub has a firewall, with default and
  RFC1918 routes pointing at it
- An optional NAT gateway and public IP per spoke, for outbound internet
  access where there is no firewall
- Hub-to-spoke and spoke-to-hub peerings for spokes that opt in

**Storage**

- An FSLogix storage account and SMB share, with a private endpoint in the
  AVD spoke and a privatelink DNS zone linked to the hub and every spoke
- Microsoft Entra Kerberos enabled on the account, with admin consent granted
  and the cloud-group-SIDs tag applied to its Entra application
- Azure RBAC on the share for the AVD user and admin groups
- NTFS permissions on the share root, set from the first session host

**Monitoring**

- A Log Analytics workspace, with diagnostics from every VNet, the storage
  account, the Azure Firewall and every AVD control plane resource
- Azure Monitor Agent on each session host, with a data collection rule
  carrying Microsoft's AVD Insights counter and event set including both
  FSLogix channels
- An action group and six alerts: session host availability, connection failure
  rate, FSLogix errors, disk space, CPU and memory

**AVD**

- Any number of pooled host pools, each with its own desktop application
  group, all surfaced through a single workspace
- Session hosts per host pool, built from a gallery image, Entra-joined,
  optionally enrolled in Intune, and registered with their host pool
- The Desktop Virtualization User role on each application group, and Virtual
  Machine User Login on the session hosts, so desktops are both visible and
  usable without a manual step

**Entra ID**

- The AVD users and admins groups, created if you want them created

**Everywhere**

- Tags on every resource that supports them, and on the resource groups.
  Subnets, peerings, role assignments, diagnostic settings and data collection
  rule associations do not take tags — an Azure limitation, so coverage is
  never quite complete.
- A session host time zone, and separately time zone redirection so each
  session adopts the time zone of the client connecting to it. Different
  mechanisms; they combine.

## Before you deploy: the Entra bootstrap

Creating Entra groups and finishing the Entra Kerberos setup are Microsoft
Graph operations. The Azure portal's deployment flow carries no Graph token, so
a template deployed from a Create blade cannot do either by itself — the
Microsoft Graph Bicep extension is GA but documented to fail with 401 inside a
Template Spec, and portal deployments fail with "Insufficient privileges to
complete the operation".

The way round it is a deployment script running as a **user-assigned managed
identity**, which does carry an app-only Graph token. That identity is created
once per tenant:

```
.\scripts\bootstrap-entra-identity.ps1 -Location northeurope
```

It prints a resource ID. Paste that into the wizard's **Entra ID** tab, or set
`entraManagedIdentityId` in the parameters file.

What it grants, and why each one:

| Permission | Needed for |
|---|---|
| `Group.ReadWrite.All` | Creating the access groups, and reading first so redeployment does not create duplicates |
| `Application.ReadWrite.All` | Adding the `kdc_enable_cloud_group_sids` tag to the storage account's application |
| `DelegatedPermissionGrant.ReadWrite.All` | Granting admin consent on that application |
| `Reader` (Azure RBAC, subscription) | Not for the work itself — the script container runs `az login --identity` before your script, and that fails when the identity can see no subscription |

These are tenant-wide permissions. Read them before running the script.

**Who can run it:** granting Microsoft Graph app roles specifically requires
Global Administrator or Privileged Role Administrator. Application
Administrator is not enough, which catches people out.

**Who can then deploy:** whoever runs the deployment needs **Managed Identity
Operator** on that identity, as well as their usual rights. Contributor or
Owner on its resource group both include it.

Leaving `entraManagedIdentityId` empty is supported. The rest of the template
deploys normally, group object IDs are taken as parameters instead, and the
Entra work becomes four manual steps. The `entraWorkSkippedNoIdentity` output
says so.

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
deployment output lists any spoke in that state.

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
  spoke.bicep                   one spoke VNet and its subnets
  peering.bicep                 one peering, used twice per spoke
  nsg.bicep                     AVD or empty NSG
  routeTable.bicep              forced routing through the hub firewall
  natGateway.bicep              NAT gateway and its public IP
  storage.bicep                 FSLogix account, share, Entra Kerberos
  storageRbac.bicep             share-level role assignments
  storageEntraKerberos.bicep    admin consent and the cloud group SIDs tag
  fslogixPrivateAccess.bicep    DNS zone, VNet links, private endpoint
  fslogixNtfsPermissions.bicep  NTFS on the share root, via Run Command
  logAnalytics.bicep            workspace
  vnetDiagnostics.bicep         per-VNet diagnostic settings
  storageDiagnostics.bicep      storage diagnostic settings
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
  { name: 'avd',  addressPrefix: '10.3.0.0/16', role: 'avd',  peerToHub: true, natGateway: true }
  { name: 'prod', addressPrefix: '10.1.0.0/16', role: 'none', peerToHub: true, natGateway: false }
]
```

`role: 'avd'` marks the spoke that will host session hosts and the storage
private endpoint; its subnets get private endpoint network policies disabled.
Exactly one spoke should have it.

Subnets reference their spoke by name:

```bicep
param subnets = [
  { spoke: 'avd',  name: 'hosts',   prefix: '10.3.0.0/24', nsgType: 'avd',   useNatGateway: true,  hostsPrivateEndpoints: true }
  { spoke: 'prod', name: 'servers', prefix: '10.1.0.0/24', nsgType: 'empty', useNatGateway: false, hostsPrivateEndpoints: false }
]
```

Both arrays are flat — every field is a string, number or boolean — so the
portal form can collect them in a grid without nesting.

Session hosts land in the AVD spoke's first subnet with `nsgType: 'avd'`. That
is not arbitrary: the AVD rule set exists to document the outbound destinations
session hosts need, so a subnet carrying it is by definition the session host
subnet. If there is no such subnet they are skipped, and
`sessionHostsSkippedNoSubnet` says so.

## The firewall switch

`hubFirewallType` drives three things at once, so they cannot drift apart:

| | `'none'` | `'fortigate'` | `'azureFirewall'` |
|---|---|---|---|
| Hub subnets | none | four FortiGate NIC subnets | `AzureFirewallSubnet`, plus `AzureFirewallManagementSubnet` on Basic |
| The appliance | — | yours to deploy | deployed, with an AVD egress policy |
| Firewall IP for routes | — | `hubFirewallInternalIp`, by hand | read from the resource |
| Spoke route tables | not created | one per spoke, default + RFC1918 via the firewall | same |
| Peering forwarded traffic | disabled | enabled in both directions | enabled in both directions |

The last row matters: without forwarded traffic allowed on both sides of a
peering, spoke-to-spoke traffic forwarded by the firewall is dropped at the
peering rather than reaching its destination.

`hubFirewallInternalIp` is required for `'fortigate'` only. With Azure Firewall
the private IP is an output of the resource, so there is nothing to transcribe
and nothing to get wrong.

### Azure Firewall

The policy carries Microsoft's documented AVD egress rules, so session hosts
work through it without further configuration: the `WindowsVirtualDesktop` FQDN
tag, service tags for the control plane and platform, RDP Shortpath STUN on UDP
3478, Windows activation on 1688, the Entra join and sign-in endpoints, the
certificate endpoints, and the Azure Monitor Agent control endpoints.

Three of those are worth knowing about, because each one fails quietly if
omitted:

- **Six certificate endpoints are HTTP on port 80**, not HTTPS. An HTTPS-only
  rule set breaks attestation certificate provisioning.
- **`pas.windows.net` is not in the AVD required-URL list** and is not reliably
  covered by the `AzureActiveDirectory` service tag. Without it the host joins
  Entra ID and then nobody can sign in to it.
- **Windows activation uses a service tag, not a hostname.** FQDN filtering in
  a network rule needs DNS proxy and is unavailable on Basic, and port 1688
  cannot go in an application rule at all since those are HTTP and HTTPS only.

Ordering is handled: the firewall depends on its rule collection group, and the
spoke route tables depend on the firewall. Session hosts Entra join at first
boot, and a default route pointing at a firewall with no rules yet would fail
that join silently.

**The Basic tier is not a cheaper Standard.** It requires a management NIC in
its own `AzureFirewallManagementSubnet` with a second public IP — unconditional,
not a forced-tunnelling option — and it tops out at 250 Mbps, which is a real
ceiling for a pooled estate. Standard is the default for good reason.

Stopping and starting a firewall can change its private IP. If you deallocate
one to save money, redeploy afterwards so the spoke routes are refreshed.

## Session hosts

Hosts are built per host pool from the `sessionHostCount` and `vmSize` fields
on each `hostPools` entry. Everything else — image, disk type, local admin
account — is shared by every pool, because in practice one customer runs one
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
configuration — profile container settings are still yours to apply.

Only 24H2 and newer are offered, and `sessionHostImageSku` is constrained to
them. Cloud-only Entra Kerberos does not support older builds, so a 23H2 host
deploys perfectly and then cannot mount a profile — better to fail validation.

### The DSC artifact URL

`sessionHostArtifactsLocation` points at Microsoft's AVD agent package:

```
https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02797.442.zip
```

Microsoft version-stamps this file, publishes no "latest" alias, and does not
document the current version anywhere. If session host registration starts
failing, that is the first thing to check. The current value is visible in the
template the portal generates from **Host pools → Add virtual machines →
Review + create → Download a template for automation**.

### Registration tokens

The session host module reads the token directly from the host pool with
`listRegistrationTokens()` and puts it in the DSC extension's protected
settings. It never passes through a module output, and it is never a deployment
output — deployment history persists indefinitely, and a registration token is
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
Azure file share root is **explicit, not inherited** — a share root has no
parent directory — so `icacls /inheritance:r` removes nothing and still exits
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
credential that bypasses NTFS — exactly what you need to set initial
permissions on a share nobody can reach. It also means the step does not depend
on Entra Kerberos having finished.

The trade is that the step needs `storageAllowSharedKeyAccess` true and a
reachable file endpoint — either the private one or `storagePublicNetworkAccess`
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
the account key — which is the only credential that bypasses NTFS, and
therefore the only way to set the initial permissions on a share nobody can yet
reach.

Neither should survive into production. Once a client has mounted the share
successfully over the private endpoint, redeploy with both tightened.

The `storageHardeningRequired` output is `true` while either is still in its
bootstrap value. It exists because the alternative is someone seeing a green
deployment, ticks all the way down, and never coming back.

## Deploying

**Deployment is through the template spec and its portal wizard.** That is the
point of the project — a form anyone can fill in, not a parameters file only
its author understands. The command line is for validating changes before
publishing them, not for deploying.

```
az login
az account set --subscription "<subscription>"

.\scripts\publish-templatespec.ps1 -Location northeurope -Version 1.3.0
```

Then **Template specs** → **avd-landing-zone** → the version → **Deploy**.

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
resources — what-if cannot evaluate what they do.

Expected resource counts:

| Configuration | Resources |
|---|---|
| The example file: 2 spokes, NAT, storage, monitoring, 1 pool, 2 hosts | ~55 |
| Same with `deploySessionHosts` false | ~42 |
| Same with `hostPools` empty | ~34 |
| Same with storage and monitoring off too | 17 |

Each session host adds four resources: NIC, VM, Entra join extension and AVD
agent extension. Counts are approximate — what-if sometimes groups
sub-resources differently, and deployment scripts each create a transient
storage account and container instance that are cleaned up afterwards.

## Validation status

All files compile and lint clean with Bicep CLI 0.47.16. The example parameters
validate with `bicep build-params`.

**Deployed and verified against a live tenant:** hub, spokes, subnets, NSGs,
NAT gateway, peerings, storage account with private endpoint and DNS, Log
Analytics with diagnostics, host pool, application group and workspace. All
guard outputs returned clean.

**Not yet exercised against a live tenant:** session hosts, the Entra bootstrap
and group creation, the Entra Kerberos consent and tagging script, and the NTFS
Run Command. Also untested: the FortiGate hub path, the Bastion subnet, and
more than one host pool.

`what-if` and `build` catch template errors. They do not catch quota, image
availability, tenant policy, or anything a deployment script does at runtime —
and note that `what-if` cannot evaluate deployment scripts at all.

### Known runtime risks

- **`MicrosoftGraphRequestFailed` when enabling Entra Kerberos.** Caused by a
  tenant-wide app management policy restricting `passwordAddition` or
  `symmetricKeyAddition`, which blocks the Storage resource provider from
  adding its own credential. The fix is an app management policy exception
  assigned to the Storage RP's service principal, app ID
  `a6aa9161-5291-40bb-8c5c-923b567bee3b`. This affects the portal, CLI and
  PowerShell identically — it is not specific to ARM.
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
Monitor Agent against a data collection rule. There is no workbook to deploy —
Insights is a built-in portal experience that discovers whatever data is there.

Two counters in Microsoft's published list are display names rather than valid
counter specifiers, and copying them verbatim collects nothing while reporting
success:

| As documented | As it must be written |
|---|---|
| `Logical Disk(C:)` | `LogicalDisk(C:)` — no space |
| `Memory(*)` | `Memory` — the object has no instances |

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
VMs, so hosts added or rebuilt later are covered with no template change —
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
  query — it already returns the IDs it saw, to make that easy.
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
success anyway** — the deployment goes green, the session hosts appear in the
host pool, and users get a credential prompt that never accepts a correct
password. `dsregcmd /status` on the host shows `AzureAdJoined : NO`.

Keep the identity and template spec resource groups; everything else goes:

```
az group delete --name rg-avd --yes --no-wait
az group delete --name rg-hub --yes --no-wait
az group delete --name rg-storage --yes --no-wait
az group delete --name rg-mgmt --yes --no-wait
```

The Entra groups created by the deployment are left alone deliberately — they
may hold membership you want to keep. Delete them by hand if you want a clean
tenant.

## Deployment guards

Outputs that flag configurations which deploy successfully but do not work.
None block the deployment — Bicep has no non-experimental assertion mechanism —
so read them on the deployment's Outputs blade once it finishes.

| Output | Meaning |
|---|---|
| `spokesWithoutOutbound` | Spokes with no NAT gateway and no firewall route. Their VMs have no internet. |
| `storageHasNoPrivateEndpoint` | Storage deployed but no subnet was flagged `hostsPrivateEndpoints`, so the share is reachable only over its public endpoint. |
| `resourceGroupNameCollisions` | A spoke named `storage` or `mgmt` produces the same resource group name as the shared storage or monitoring group. |
| `hostPoolsSkippedNoAvdSpoke` | Host pools were defined but no spoke has `role: 'avd'`, so the control plane was skipped entirely. |
| `sessionHostsSkippedNoSubnet` | Session hosts were requested but the AVD spoke has no subnet with `nsgType: 'avd'` to put them in. |
| `duplicateSessionHostPrefixes` | Two host pools produce the same VM name prefix. Set `vmNamePrefix` on one. |
| `entraWorkSkippedNoIdentity` | Entra work was requested but no managed identity was supplied, so groups, consent and the manifest tag were all skipped. |
| `fslogixNtfsPermissionsSkipped` | NTFS permissions could not be set — no session host to run from, or no users group. Until they are, every user can read every other user's profile. |
| `bastionPrefixValid` | `false` when `bastionSubnetPrefix` is smaller than `/26`, which Azure rejects. |
| `azureFirewallPrefixValid` | `false` when `AzureFirewallSubnet` is smaller than `/26`. |
| `azureFirewallMgmtPrefixValid` | `false` when `AzureFirewallManagementSubnet` is smaller than `/26`. Basic tier only. |
| `alertsHaveNoRecipient` | Alerts deployed with no email address. They fire, nobody is told. |
| `insightsSkippedNoWorkspace` | Insights requested but monitoring is off, so the agent was not installed. |
| `storageHardeningRequired` | Storage is still in its bootstrap posture — shared key access on, or the public endpoint open. |

Everything should be empty or false except the three `...Valid` outputs, which
should be true.

**These are deployment outputs, not what-if output.** What-if reports resource
changes only; outputs are evaluated during a real deployment. They save
troubleshooting time; they are not a pre-flight check.

Two other outputs are there to be used rather than checked:
`storageEntraApplicationId` is what you search for when excluding the storage
app from MFA, and `avdUsersGroupId` / `avdAdminsGroupId` report the groups that
were created.

## Portal wizard

`uiFormDefinition.json` is what gives the template its Create blade, and it is
the intended way in. The eight tabs collect the same values the parameters file
holds, with validation, dropdowns and grids instead of hand-edited arrays.

| Tab | What it collects |
|---|---|
| Basics | Subscription, region and tags |
| Hub | Hub network, firewall choice and tier, optional Bastion subnet |
| Spokes | A grid — one row per spoke |
| Subnets | A grid — one row per subnet, matched to a spoke by name |
| Storage | FSLogix account and private endpoint, or off |
| Monitoring | Log Analytics, AVD Insights, alerts and the notification email |
| AVD | Host pools, desktop names, workspace, session host image, size, local admin, time zone, FSLogix |
| Entra ID | The managed identity, group creation, Kerberos setup, NTFS |

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

Twenty-four parameters are deliberately not exposed — TLS version, shared key
access, public network access, retention SKU, the DSC artifact URL, the
Entra Kerberos and default share permission switches, and similar. They keep
their defaults from `main.bicep`. Anyone needing to change those should use the
parameters file directly.

## Known limitations

- Greenfield only. Creates its own resource groups and VNets; does not consume
  existing hub, DNS or Log Analytics infrastructure.
- Cloud-only identities only. Hybrid environments needing AD DS Kerberos, a
  domain controller, custom VNet DNS or on-premises connectivity are not
  supported by this design.
- The Entra work needs a bootstrap identity with tenant-wide Graph
  permissions. There is no way round this from a portal Create blade — the
  Microsoft Graph Bicep extension does not work in one, and Microsoft has an
  open issue with no committed date.
- Excluding the storage application from MFA Conditional Access is always
  manual.
- FortiGate is subnets only — the appliance, its licensing and its HA pairing
  are yours. Azure Firewall is the path the template deploys end to end.
- The AVD NSG rules are **informational service-tag rules, not a complete AVD
  allowlist**. They do not contain everything Microsoft currently documents —
  UDP 3478 and several platform endpoints are absent — and they restrict
  nothing, because Azure's default `AllowInternetOutBound` still applies.
  Real egress control means a firewall, which is what the Azure Firewall path
  is for.
- Empty NSGs are attachment points, not segmentation.
- The Bastion `/26` minimum is surfaced as the `bastionPrefixValid` output
  rather than failing the deployment.
- A spoke with no outbound path deploys successfully and fails at runtime.
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
  module, which `main.bicep` does not currently expose — raising
  `sessionHostCount` and redeploying rebuilds from index 0 and collides.
- Pooled host pools only. Personal (1:1) host pools are not supported.
- Desktop application groups only. RemoteApp is not implemented.
- Does not deploy Bastion hosts or backup.
