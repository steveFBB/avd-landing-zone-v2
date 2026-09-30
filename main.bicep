// =============================================================================
// AVD landing zone — v2 (loop-based)
// =============================================================================
// Stage 2: hub + spokes, NSGs, route tables, peerings.
//
// Identity model: CLOUD-ONLY. FSLogix storage will use Microsoft Entra
// Kerberos with cloud-only identities, so no domain controller, no custom
// VNet DNS, and no on-premises connectivity are required. Session hosts
// must be Entra-joined, and must run Windows 11 24H2+ or Server 2025 —
// cloud-only Entra Kerberos does not support older builds.
//
// Unlike v1, the number of spokes and subnets is not fixed. Spokes are
// defined as an array and looped; each spoke's subnets are matched to it by
// name. One spoke or five, same code.
//
// Names are DERIVED, not supplied:
//   rg-<spoke>              e.g. rg-avd
//   vnet-<spoke>            e.g. vnet-avd
//   snet-<spoke>-<subnet>   e.g. snet-avd-hosts
//   nsg-<spoke>-<subnet>    e.g. nsg-avd-hosts
//   rt-<spoke>              e.g. rt-avd
//
// Still to come: storage + private endpoint + DNS, Log Analytics and
// diagnostics, AVD control plane.
// =============================================================================

targetScope = 'subscription'

@description('''Tags applied to every resource this template creates that supports
them. Resource groups are tagged too.

Not everything in Azure takes tags — subnets, peerings, role assignments, diagnostic
settings and data collection rule associations do not — so coverage is never quite
complete. That is Azure, not the template.''')
param tags object = {}

@description('''Tags as an array of { name, value } pairs, which is the shape a portal
grid can produce — the form has no reliable way to build an object.

Merged with `tags` above rather than replacing it, so the parameters file and the wizard
can both be used without one silently discarding the other.''')
param tagPairs array = []

@description('''Time zone for session hosts, as a Windows time zone ID such as
\'GMT Standard Time\' or \'Eastern Standard Time\'. Empty leaves the Azure default, which
is UTC.

This sets the HOST\'s clock. To have each user see their own local time instead, use
enableTimeZoneRedirection below — they are different mechanisms and can be combined.''')
param sessionHostTimeZone string = ''

@description('''Allow time zone redirection, so a session adopts the time zone of the
client connecting to it rather than the host\'s.

Usually what people mean by "set the timezone" when users are spread across regions.
Applied as the Allow time zone redirection policy on each host; takes effect for new
sessions, with no restart needed.''')
param enableTimeZoneRedirection bool = false

param location string

//
// NETWORK
//
@description('''Where the VNets come from.

  create    This deployment creates them, from the Spokes and Subnets tabs.
  existing  They already exist. You point at the subnets the session hosts and the
            FSLogix private endpoint should use, and nothing network-shaped is created.

Microsoft's own AVD accelerator treats both as first class, and for a customer who
already has Azure the second is the normal case: the network belongs to their platform
team, not to an AVD workload. This template never creates a hub for the same reason —
a hub carries the customer's gateway, firewall and domain controllers, and an AVD
workload peers into it.''')
@allowed([
  'create'
  'existing'
])
param networkMode string = 'create'

@description('Existing subnet for the session hosts, as a full resource ID. Required when networkMode is existing.')
param existingSessionHostSubnetId string = ''

@description('''Existing subnet for the FSLogix private endpoint, as a full resource ID.
May be the same subnet as the session hosts. Empty skips the private endpoint, and the
share is then reached over its public endpoint.''')
param existingPrivateEndpointSubnetId string = ''

@description('''Resource group for the AVD resources — host pool, application group,
workspace and session hosts. Required when networkMode is existing. Ignored when
creating, where they go in the AVD spoke's own resource group.''')
param avdResourceGroupName string = ''

@description('''Existing hub VNet to peer the created VNets to, as a full resource ID.
Empty creates no peerings.

Both sides of a peering have to exist. The hub side can only be created when the hub is
in this same subscription; otherwise their network team adds it and
hubSidePeeringNotCreated says so.''')
param peerToExistingHubVnetId string = ''

@description('''How VMs in the created VNets reach the internet.

  natGateway  A NAT gateway per VNet that asks for one, on the Spokes tab. Microsoft's
              recommendation for AVD: predictable outbound addresses without putting the
              AVD service traffic through an inspection device.
  firewall    A default route to a firewall that ALREADY EXISTS, by its private IP.
              Route tables are created and attached; the firewall is not.
  none        Neither. Correct only when the subnets are not private, or when something
              outside this deployment provides egress.

Session hosts reach the AVD service over the internet to register, so a host with no
egress never comes up.''')
@allowed([
  'natGateway'
  'firewall'
  'none'
])
param egressMode string = 'natGateway'

@description('Private IP of the existing firewall to route through. Required when egressMode is firewall.')
param firewallPrivateIp string = ''

//
// SPOKES
//
@description('''Spokes to create. One row per spoke in the GUI.
Each entry: {
  name          string  short name, e.g. 'avd' — drives all derived names
  addressPrefix string  e.g. '10.3.0.0/16'
  role          string  'avd' (hosts session hosts and the storage private
                        endpoint) or 'none'
  peerToHub     bool    create hub<->spoke peerings in both directions. Absent or
                        false under standalone topology, where there is no hub.
  natGateway    bool    create a NAT gateway + public IP in this spoke.
                        Costs money per spoke — a NAT gateway cannot be
                        shared across VNets. Which subnets actually use it
                        is set per subnet below.
  rgName                  Optional. Resource group name, exactly as you want it.
                          Blank derives rg-<name>.
  vnetName                Optional. VNet name, exactly as you want it. Blank
                          derives vnet-<name>.
  dnsServers              Optional. Overrides the template-wide dnsServers for this
                          spoke only. Not on the wizard — set it in a parameters file
                          if one VNet needs different resolvers from the rest.
}

'name' is a key, not a resource name: subnets reference their parent spoke by it and
the resource groups and VNets are named by rgName and vnetName.''')
param spokes array

@description('''Subnets, matched to their parent spoke by the `spoke` field.
Each entry: {
  spoke                 string  must match a spokes[].name
  name                  string  the subnet's name, exactly as you want it. The NSG
                                for it is named nsg-<name>.
  prefix                string  e.g. '10.3.0.0/24'
  nsgType               string  'avd' (documented AVD outbound allow rules)
                                or 'empty'
  useNatGateway         bool    attach to the spoke's NAT gateway. Ignored
                                when the spoke has natGateway = false.
  hostsPrivateEndpoints bool    the FSLogix private endpoint lands here, and
                                this subnet gets private endpoint network
                                policies disabled. Exactly one subnet in the
                                AVD spoke should have this set.
}

'spoke' joins a subnet to its parent VNet and must match a spokes[].name exactly.''')
param subnets array

@description('''Set spoke subnets private (defaultOutboundAccess = false), removing
Azure's implicit outbound internet path. Azure is retiring default outbound access
for VNets created with API versions after 31 March 2026; setting this true makes
behaviour explicit rather than dependent on the template's API version.

A subnet that is private with no NAT gateway and no route to a firewall has NO
outbound internet. The deployment still succeeds — the failure shows up later as
session hosts unable to reach the AVD service. Check the spokesWithoutOutbound
output.''')
param privateSubnets bool = true

//
// STORAGE
//
@description('Deploy the FSLogix storage account, share, private endpoint and DNS. Off means no storage at all.')
param deployStorage bool = true

@description('Resource group for the storage account and its private DNS zone. Must not collide with a spoke name, since spokes create rg-<name>.')
param storageRgName string = 'rg-storage'

@description('Globally unique across all of Azure. Lowercase letters and digits only, 3-24 characters.')
param storageAccountName string = ''

param storageSku string = 'Premium_LRS'
param storageAccountKind string = 'FileStorage'
param storageAccessTier string = 'Hot'
param fileShareName string = 'profiles'
param fileShareQuotaGiB int = 512

param storageMinimumTlsVersion string = 'TLS1_2'
param storageSupportsHttpsTrafficOnly bool = true
param storageAllowBlobPublicAccess bool = false
param storageAllowSharedKeyAccess bool = true
param storagePublicNetworkAccess string = 'Enabled'
param storageLargeFileSharesState string = 'Enabled'

param fslogixPrivateEndpointName string = 'pe-fslogix-file'

@description('''Enable Microsoft Entra Kerberos on the storage account. This is what lets
FSLogix authenticate to the share with cloud-only identities. Turning it off leaves the
share with no SMB identity source and no way for profiles to work.''')
param storageEnableEntraKerberos bool = true

@description('''Share-level permission for every authenticated identity, beneath the
per-group assignments. Leave \'None\' unless you know why you are changing it — anything
else applies to every share in the account and cannot be scoped to one.''')
@allowed([
  'None'
  'StorageFileDataSmbShareReader'
  'StorageFileDataSmbShareContributor'
  'StorageFileDataSmbShareElevatedContributor'
])
param storageDefaultSharePermission string = 'None'

@description('''Set NTFS permissions on the share root from the first session host.
Azure RBAC governs who reaches the share; NTFS governs what they can do on it, and the
default NTFS permissions let every user open every other user\'s profile. Requires
session hosts and a users group.''')
param setFslogixNtfsPermissions bool = true

//
// IDENTITY MODEL
//
// The first decision, because almost everything else follows from it.
//
@description('''Where the identities come from.

  entraOnly  Cloud only. Session hosts join Microsoft Entra ID directly, the access
             groups can be created by the deployment, and no domain controller is
             involved anywhere.

  hybrid     Users and groups live in on-premises Active Directory and are synced to
             Entra ID. THE LANDING ZONE IS BUILT WITHOUT SESSION HOSTS: networks,
             storage, monitoring and the AVD control plane are created, and the hosts
             are not, because there is no domain controller for them to join yet.
             Add a domain controller afterwards, then create the hosts with whatever
             process you use for that. Host pool rows are still honoured — the pools,
             application groups and workspace are created and left empty.

Access groups can be created by the deployment under either model, or their object IDs
supplied. Under hybrid, a group created here is cloud-only: fine for Azure RBAC, but it
cannot be managed from on-premises AD, and a synced AD group is the safer choice once
file-level NTFS permissions on the profile share come into play.''')
@allowed([
  'entraOnly'
  'hybrid'
])
param identityModel string = 'entraOnly'

@description('''Hybrid only. Tick once the domain controller exists in the hub and Entra
Connect is syncing users and groups.

Until then the Entra Kerberos setup is deferred: the storage account is created without
AADKERB and the admin consent script does not run. Both need users already synced from
Active Directory, and on a first pass there is no domain controller and no sync, so
enabling them would configure something that cannot work and would fail or sit broken
until someone noticed.

Deploy the landing zone with this unticked, build the domain controller, get Entra
Connect running, then redeploy with it ticked. Ignored when identityModel is
entraOnly, where there is nothing to wait for.''')
param hybridDomainControllerReady bool = false

@description('''DNS servers for every VNet this template creates, comma or semicolon
separated. Empty uses Azure-provided DNS.

Azure-provided DNS is correct for a cloud-only deployment: it resolves privatelink zones
linked to the VNet, so the FSLogix private endpoint works with no DNS servers of your own.

A hybrid deployment sets this to its domain controllers, but only once they exist. On a
first pass they do not, so pointing the VNets at them breaks resolution for everything,
the storage private endpoint included.

Setting this makes those servers responsible for ALL resolution from the VNet,
privatelink included — they must forward to 168.63.129.16 or the storage account
resolves to its public IP and profiles stop mounting.

A spoke row carrying its own dnsServers overrides this for that spoke.''')
param dnsServers string = ''

//
// ENTRA ID
//
// The bootstrap managed identity exists because the Azure portal's deployment
// flow carries no Microsoft Graph token: a template deployed from a Create
// blade cannot create groups or finish the Entra Kerberos setup on its own. A
// deployment script running as this identity can.
//
// It is created once per tenant by scripts/bootstrap-entra-identity.ps1, which
// names it from the two defaults below. Because that script is ours, the name
// is a convention rather than a customer-specific value — so the identity is
// found by name and nothing has to be typed or pasted into the wizard.
@description('Use the bootstrap managed identity for the Entra work. Off skips group creation and the Entra Kerberos setup; supply group object IDs instead.')
param useEntraManagedIdentity bool = true

@description('''Name of the bootstrap managed identity. Matches the default in
scripts/bootstrap-entra-identity.ps1, so there is nothing to supply. Deliberately not on
the wizard — override it in a parameters file on the rare occasion the script was run
with -IdentityName.''')
param entraManagedIdentityName string = 'id-avd-entra-ops'

@description('''Resource group holding the bootstrap managed identity. Matches the
default in scripts/bootstrap-entra-identity.ps1. Deliberately not on the wizard —
override it in a parameters file if the script was run with -ResourceGroup.''')
param entraManagedIdentityRgName string = 'rg-identity'

@description('''Create the AVD access groups rather than taking their object IDs as
parameters. Requires the bootstrap managed identity. The groups are matched by display name, so
redeploying reuses the existing ones instead of creating duplicates.''')
param createEntraGroups bool = false

@description('Display name for the AVD users group when createEntraGroups is true.')
param avdUsersGroupName string = 'AVD Users'

@description('Display name for the AVD admins group when createEntraGroups is true.')
param avdAdminsGroupName string = 'AVD Admins'

@description('''Grant admin consent and apply the kdc_enable_cloud_group_sids tag to the
application the Storage resource provider creates for the account. Both are mandatory
for cloud-only Entra Kerberos and neither can be expressed as an ARM resource. Requires
the bootstrap managed identity.''')
param configureEntraKerberos bool = true

@description('''Azure CLI image version for the deployment script containers. Any tag
published at mcr.microsoft.com/azure-cli is valid, but the deployment script service
keeps its own supported list, which is shorter and drops old versions over time.

If a script fails with DeploymentScriptBootstrapScriptExecutionFailed — meaning the
container never started, so nothing in the script ran — a stale version here is one of
the few things you control. Bump it before assuming the failure is yours.''')
param deploymentScriptAzCliVersion string = '2.85.0'

@description('''Keep the deployment script\'s container instance and transient storage
account after a run, instead of only after a failure. Costs a little and clutters the
resource group, but it is the only way to read the container events when a script fails
and you are not watching. Turn it on while debugging, off afterwards.''')
param retainDeploymentScriptArtifacts bool = false

@description('Entra ID object ID of the AVD users group. Ignored when createEntraGroups is true. Empty skips the role assignments.')
param avdUsersGroupObjectId string = ''

@description('Entra ID object ID of the AVD admins group. Ignored when createEntraGroups is true. Empty skips the role assignments.')
param avdAdminsGroupObjectId string = ''

//
// MONITORING
//
@description('Deploy the Log Analytics workspace and send VNet and storage diagnostics to it.')
param deployMonitoring bool = true

@description('Resource group for the Log Analytics workspace. Must not collide with a spoke name.')
param monitoringRgName string = 'rg-mgmt'

param logAnalyticsWorkspaceName string = 'law-avd'
param logAnalyticsRetentionDays int = 30
param logAnalyticsSku string = 'PerGB2018'

@description('''Collect session host performance counters and event logs for AVD
Insights — an Azure Monitor Agent on each host and a data collection rule carrying
Microsoft's documented counter and event set, plus the FSLogix channels.

Needs monitoring deployed, since the data has to land somewhere.''')
param deployAvdInsights bool = true

@description('Also collect per-process input delay. Instances scale with processes times sessions, so this is a large share of ingestion cost for detail you rarely act on.')
param collectPerProcessInputDelay bool = false

@description('''Deploy an action group and the starter alert set: session host
availability, connection failure rate, FSLogix errors, disk space, CPU and memory.''')
param deployAlerts bool = true

@description('Email address for alerts. Empty still creates the action group and the rules, so alerts fire and are visible in the portal, but nobody is told.')
param alertEmailAddress string = ''

@description('Short name shown in alert emails. Azure caps it at 12 characters.')
@maxLength(12)
param alertActionGroupShortName string = 'avdops'

param cpuAlertThresholdPercent int = 85
param memoryAlertThresholdPercent int = 10
param diskFreeAlertThresholdPercent int = 10

//
// AVD CONTROL PLANE
//
@description('''Host pools to create. One row per host pool in the GUI.
Each entry: {
  name             string  short name — becomes hp-<name> and ag-<name>-desktop
  friendlyName     string  what users see in the AVD client
  maxSessionLimit  int     concurrent sessions per session host
  startVMOnConnect bool    power hosts on when a user connects
  sessionHostCount int     session hosts to build for this pool. Optional;
                           0 or absent creates the pool with no hosts.
  vmSize           string  session host VM size. Optional; required only when
                           sessionHostCount is above 0.
  vmNamePrefix     string  optional override for the VM name prefix. Defaults
                           to the pool name, lowercased, hyphens stripped and
                           truncated to 11 characters.
}
An empty array deploys no control plane at all. Every host pool gets its own
desktop application group; all of them surface through the single workspace.
All pools are Pooled with depth-first load balancing.''')
param hostPools array = []

@description('''Custom RDP properties applied to every host pool, semicolon separated.

The default carries targetisaadjoined:i:1, which Entra-joined session hosts need
before a client that is not Entra joined to the same tenant can connect. Without
it the user gets a credential prompt that never accepts a correct password.''')
param hostPoolCustomRdpProperties string = 'targetisaadjoined:i:1;'

param avdWorkspaceName string = 'ws-avd'
param avdWorkspaceFriendlyName string = 'AVD Workspace'

@description('''Registration token expiry as an ISO 8601 timestamp, shared by every
host pool. The default is 30 days from deployment time — do not set this in the
parameters file unless you have a reason to.

The token is not returned as an output, because deployment outputs persist in
deployment history. Fetch it with:
  az desktopvirtualization hostpool retrieve-registration-token \\
    --resource-group <rg> --host-pool-name <name>''')
param registrationTokenExpiry string = dateTimeAdd(utcNow(), 'P30D')

// Rename each published desktop. Needs a REST call, so it is a deployment
// script; see the module header for why no Bicep resource can do this.
module avdDesktopNames 'modules/avdDesktopName.bicep' = if (doDesktopNames) {
  name: 'avdDesktopNames'
  scope: resourceGroup(avdRgName)
  dependsOn: [
    avdApplicationGroups
  ]
  params: {
    tags: allTags
    location: location
    managedIdentityId: entraIdentityId
    managedIdentityPrincipalId: hasEntraIdentity ? entraIdentity!.properties.principalId : ''
    desktops: desktopsToRename
    azCliVersion: deploymentScriptAzCliVersion
    retainArtifacts: retainDeploymentScriptArtifacts
  }
}

//
// SESSION HOSTS
//
// Session hosts are created per host pool, via the sessionHostCount and
// vmSize fields on each hostPools entry. Everything below is shared by every
// pool, because in practice one customer runs one image and one disk type.
//
@description('''Master switch for session hosts. False deploys the control plane only —
host pools, application groups and workspace with no VMs — whatever sessionHostCount
says on each pool. Useful when session hosts are built by a separate image pipeline.''')
param deploySessionHosts bool = true

@description('''Local administrator account created on every session host. A break-glass
account — users sign in with their Entra credentials, not this one. Required when any
host pool has sessionHostCount above 0.

Deliberately NOT marked @secure(). A username is not a secret, and marking it secure
means the portal feeds a plain text box into a securestring, and the value never appears
in deployment history — so when it arrives empty, as it did, there is no way to see
what was sent.''')
param sessionHostAdminUsername string = ''

@description('Password for the local administrator account. Azure requires 12-123 characters with three of: uppercase, lowercase, digit, symbol.')
@secure()
param sessionHostAdminPassword string = ''

@description('Marketplace image publisher for session hosts.')
param sessionHostImagePublisher string = 'microsoftwindowsdesktop'

@description('''Marketplace image offer. The Microsoft 365 images are published under
\'office-365\', NOT under \'windows-11\' — this catches people out. Use
\'windows-11\' only for the images without Microsoft 365 Apps preinstalled.''')
param sessionHostImageOffer string = 'office-365'

@description('''Marketplace image SKU. Defaults to Windows 11 Enterprise multi-session
25H2 with Microsoft 365 Apps. The equivalents without M365 are win11-25h2-avd and
win11-24h2-avd, under the windows-11 offer.

23H2 and older are deliberately not offered: cloud-only Entra Kerberos does not
support them, so such a host deploys cleanly and then cannot mount a profile.''')
@allowed([
  'win11-25h2-avd-m365'
  'win11-24h2-avd-m365'
  'win11-25h2-avd'
  'win11-24h2-avd'
])
param sessionHostImageSku string = 'win11-25h2-avd-m365'

@description('Image version. \'latest\' takes the newest published image at deployment time.')
param sessionHostImageVersion string = 'latest'

@description('''OS disk size in GB for session hosts. 0 uses the image default of 128 GB.
Disks grow but never shrink, so this can be raised later and not lowered.''')
param sessionHostOsDiskSizeGB int = 0

@description('OS disk type for session hosts.')
@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
  'PremiumV2_LRS'
])
param sessionHostOsDiskType string = 'StandardSSD_LRS'

@description('''URL of the AVD DSC configuration package that installs the agent and
bootloader on each session host. Microsoft version-stamps this file and does not
publish the current version anywhere in their documentation, so it is a parameter
you may need to bump — see the README.''')
param sessionHostArtifactsLocation string = 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_1.0.02797.442.zip'

@description('Enrol session hosts in Intune during the Entra join. Multi-session hosts enrol with device credentials and need AVD agent 1.0.2944.1400 or newer.')
param sessionHostEnrolWithIntune bool = false

@description('''Configure FSLogix profile containers and cloud Kerberos on every
session host. The gallery images ship FSLogix installed but not configured, so without
this a freshly built host quietly keeps local profiles.

Skipped automatically when storage is not deployed — there would be nowhere to put the
containers.''')
param configureFslogixOnSessionHosts bool = true

@description('Maximum profile container size in MB. A ceiling, not an allocation.')
param fslogixProfileSizeMB int = 30000

@description('''Restart each session host after configuring FSLogix.
CloudKerberosTicketRetrievalEnabled is read by LSA at boot, so a host that is not
restarted cannot authenticate to the share. Leave true unless you are restarting them
yourself.''')
param restartSessionHostsAfterFslogix bool = true

@description('''Friendly name for the published desktop in each application group,
keyed by host pool. AVD names it SessionDesktop and no Bicep resource can change that,
so this is done with a REST call from a deployment script — which needs
the bootstrap managed identity, and grants it Desktop Virtualization Application Group
Contributor on the AVD resource group.

Set desktopFriendlyName on a host pool row to use it. Empty everywhere means the step
is skipped and the desktops stay called SessionDesktop.''')
param setDesktopFriendlyNames bool = true

@description('Accelerated networking on session host NICs. Not supported by B-series sizes — deployment fails outright rather than degrading, so turn this off if using one.')
param sessionHostAcceleratedNetworking bool = true

//
// DERIVED
//
// toObject() rather than string surgery on the array: a tag value containing a
// comma or a quote would break any textual conversion, and tag values routinely
// contain both.
// Rows with no name are dropped before conversion. A portal grid can hand back
// a blank row, and toObject() on an empty key produces a tag Azure rejects —
// which would fail the deployment for a row the user never filled in.
var namedTagPairs = filter(tagPairs, pair => !empty(pair.?name ?? ''))
var allTags = union(tags, toObject(namedTagPairs, pair => pair.name, pair => pair.value))

var isCreateNetwork = networkMode == 'create'

// Route tables are created only when there is an address to point them at. An
// egressMode of firewall with no IP would produce a default route to nowhere,
// which blackholes the subnet.
var routeViaFirewall = egressMode == 'firewall' && !empty(trim(firewallPrivateIp))

// Peering happens only to a hub that already exists, and only for VNets this
// deployment created. There is nothing to peer in existing mode.
var peerToHub = isCreateNetwork && !empty(trim(peerToExistingHubVnetId))

// A subnet ID is
//   /subscriptions/../resourceGroups/../providers/Microsoft.Network/virtualNetworks/<v>/subnets/<s>
// so its VNet is the same ID with the last two segments removed. Used to link
// existing VNets to the privatelink DNS zone, which otherwise resolves nothing
// and the share silently falls back to its public endpoint.
func vnetIdOfSubnet(subnetId string) string =>
  empty(trim(subnetId)) ? '' : join(take(split(trim(subnetId), '/'), 9), '/')

func lastSegment(value string) string =>
  empty(trim(value)) ? '' : last(split(trim(value), '/'))

var deployInsights = deployAvdInsights && deployMonitoring
var deployAlertRules = deployAlerts && deployMonitoring

// Flatten spokes x their subnets into one list so NSGs (which are per
// subnet) can be created in a single flat loop. Bicep handles one flat
// loop far better than a nested one.
// ---------------------------------------------------------------------------
// NAMES
// ---------------------------------------------------------------------------
// Resource groups, VNets and subnets are named exactly as typed in the grids.
// Every customer names things differently, so nothing here invents a name when
// one was given.
//
// Leaving a name blank falls back to the old pattern — rg-<spoke>,
// vnet-<spoke>, snet-<spoke>-<subnet> — so a parameter file written before
// these columns existed still deploys and still produces the same names.
//
// Looked up by spoke NAME rather than by index, because most of the places
// that need a resource group are iterating over subnets or host pools, where
// the spoke's index is not to hand.
var spokeRgByName = toObject(
  spokes,
  s => s.name,
  s => empty(trim(string(s.?rgName ?? ''))) ? 'rg-${s.name}' : trim(string(s.rgName))
)

var spokeVnetByName = toObject(
  spokes,
  s => s.name,
  s => empty(trim(string(s.?vnetName ?? ''))) ? 'vnet-${s.name}' : trim(string(s.vnetName))
)

// A subnet belonging to a spoke that does not exist has no resource group and
// no VNet to look up. Those rows are reported by subnetsWithUnknownSpoke; the
// fallback here only stops the lookup itself from failing first, which would
// produce an error naming neither the subnet nor the spoke.
var spokeSubnets = [
  for subnet in subnets: {
    spoke: subnet.spoke
    // The subnet's name, exactly as typed. There is no second short name to
    // keep in step with it: the NSG is named from this one.
    name: trim(subnet.name)
    prefix: subnet.prefix
    nsgType: subnet.nsgType
    useNatGateway: subnet.useNatGateway
    hostsPrivateEndpoints: subnet.hostsPrivateEndpoints
    nsgName: 'nsg-${trim(subnet.name)}'
    rgName: spokeRgByName[?subnet.spoke] ?? 'rg-${subnet.spoke}'
  }
]

// Locate the AVD spoke and the subnet that will host the private endpoint.
//
// Resource IDs are CONSTRUCTED here rather than read from module outputs.
// Reading them would mean indexing one loop's outputs from inside another,
// which Bicep does not support. Every name involved is derived from
// parameters, so building the ID directly is deterministic and safe —
// ordering is handled with dependsOn instead.
var avdSpokes = filter(spokes, s => s.role == 'avd')
var hasAvdSpoke = isCreateNetwork && !empty(avdSpokes)
var avdSpokeName = hasAvdSpoke ? first(avdSpokes)!.name : ''

var peSubnets = filter(spokeSubnets, s => s.spoke == avdSpokeName && s.hostsPrivateEndpoints)
var createdPeSubnet = hasAvdSpoke && !empty(peSubnets)
var peSubnetName = createdPeSubnet ? first(peSubnets)!.name : ''

var createdPeSubnetId = createdPeSubnet
  ? resourceId(
      subscription().subscriptionId,
      avdRgName,
      'Microsoft.Network/virtualNetworks/subnets',
      avdVnetName,
      peSubnetName
    )
  : ''

// One value whatever the mode, so everything downstream stays mode-agnostic.
var peSubnetId = isCreateNetwork ? createdPeSubnetId : trim(existingPrivateEndpointSubnetId)
var hasPeSubnet = !empty(peSubnetId)

// Every VNet that must resolve the FSLogix share: the hub plus all spokes.
// Linking a VNet to a private DNS zone costs nothing, so there is no reason
// to be selective here.
// A for-expression can only be the direct value of a declaration, not an
// argument to a function, so the spoke list is built separately and then
// concatenated.
var spokeVnetLinks = [
  for spoke in spokes: {
    name: spokeVnetByName[spoke.name]
    id: resourceId(
      subscription().subscriptionId,
      spokeRgByName[spoke.name],
      'Microsoft.Network/virtualNetworks',
      spokeVnetByName[spoke.name]
    )
  }
]

// The existing hub, when peering to one: its VMs need to resolve the share too.
var hubVnetLink = peerToHub ? [
  {
    name: lastSegment(peerToExistingHubVnetId)
    id: trim(peerToExistingHubVnetId)
  }
] : []

// In existing mode there are no spokes to enumerate, so the VNets to link are
// derived from the subnets the customer pointed at. Both may live in the same
// VNet, hence the union: two zone links with the same name fail.
var existingVnetIds = union(
  empty(vnetIdOfSubnet(existingSessionHostSubnetId)) ? [] : [vnetIdOfSubnet(existingSessionHostSubnetId)],
  empty(vnetIdOfSubnet(existingPrivateEndpointSubnetId)) ? [] : [vnetIdOfSubnet(existingPrivateEndpointSubnetId)]
)

var existingVnetLinks = [
  for id in existingVnetIds: {
    name: lastSegment(id)
    id: id
  }
]

var dnsLinkedVnets = isCreateNetwork ? concat(hubVnetLink, spokeVnetLinks) : existingVnetLinks


// Spokes derive rg-<name>, so a spoke called 'storage' or 'mgmt' would
// collide with the shared resource groups and the two deployments would
// fight over the same RG.
var sharedRgNames = union(
  deployStorage ? [storageRgName] : [],
  deployMonitoring ? [monitoringRgName] : [],
  isCreateNetwork || empty(avdRgName) ? [] : [avdRgName]
)
var spokeNames = [for spoke in spokes: spoke.name]

// A subnet whose parent spoke does not exist is deployed into rg-<that name>,
// which does not exist either — and the deployment fails several modules deep
// with ResourceGroupNotFound, pointing at a resource group rather than at the
// typo that caused it.
var orphanedSubnets = filter(subnets, s => !contains(spokeNames, s.spoke))

var spokeRgNames = [for spoke in spokes: spokeRgByName[spoke.name]]
var rgNameCollisions = filter(spokeRgNames, r => contains(sharedRgNames, r))

// The control plane lives in the AVD spoke's resource group, so it needs an
// AVD spoke to exist. Host pools defined without one are skipped rather
// than deployed somewhere arbitrary.
// In existing mode there is no spoke to take a resource group from, so one is
// named directly. Either way the control plane needs somewhere to go.
var avdRgName = isCreateNetwork
  ? (hasAvdSpoke ? spokeRgByName[avdSpokeName] : '')
  : trim(avdResourceGroupName)

var avdVnetName = hasAvdSpoke ? spokeVnetByName[avdSpokeName] : ''

var deployControlPlane = !empty(avdRgName) && !empty(hostPools)
var hostPoolNameList = [for pool in hostPools: 'hp-${pool.name}']

// Which subnet do session hosts land in?
//
// The AVD spoke's first subnet with nsgType 'avd'. That is not an arbitrary
// choice: the AVD NSG rule set exists specifically to document the outbound
// destinations session hosts need, so a subnet carrying it is by definition
// the session host subnet. This avoids adding another flag to the subnet grid
// and keeps the two decisions from drifting apart.
//
// If the AVD spoke has no such subnet, session hosts are skipped rather than
// placed somewhere arbitrary, and sessionHostsSkippedNoSubnet says so.
var avdHostSubnets = filter(spokeSubnets, s => s.spoke == avdSpokeName && s.nsgType == 'avd')
var createdHostSubnet = hasAvdSpoke && !empty(avdHostSubnets)

var createdHostSubnetId = createdHostSubnet
  ? resourceId(
      subscription().subscriptionId,
      avdRgName,
      'Microsoft.Network/virtualNetworks/subnets',
      avdVnetName,
      first(avdHostSubnets)!.name
    )
  : ''

// One value whatever the mode.
var sessionHostSubnetId = isCreateNetwork ? createdHostSubnetId : trim(existingSessionHostSubnetId)
var hasSessionHostSubnet = !empty(sessionHostSubnetId)
var sessionHostSubnetName = lastSegment(sessionHostSubnetId)

// Windows computer names cap at 15 characters and the module appends '-<index>',
// so the prefix is truncated to 11. Two pools whose names agree in their first
// 11 characters would produce colliding VM names — duplicateSessionHostPrefixes
// flags that rather than letting the second deployment fail mid-flight.
var sessionHostPrefixes = [
  for pool in hostPools: take(replace(toLower(string(pool.?vmNamePrefix ?? pool.name)), '-', ''), 11)
]
var sessionHostCounts = [
  for pool in hostPools: deploySessionHosts ? int(pool.?sessionHostCount ?? 0) : 0
]
var totalSessionHosts = reduce(sessionHostCounts, 0, (cur, next) => cur + next)
var anySessionHostsRequested = totalSessionHosts > 0

// Diagnostics on control plane resources are wired only when monitoring is
// deployed; an empty workspace ID skips them inside each module.
var avdDiagnosticsWorkspaceId = deployMonitoring ? logAnalytics!.outputs.workspaceId : ''

// A spoke has an outbound internet path if it routes through the hub
// firewall, or has a NAT gateway with at least one subnet attached to it.
// Anything else is a spoke whose VMs cannot reach the internet once its
// subnets are private — which for an AVD spoke means session hosts that
// never register.
// Session hosts are the one thing that cannot survive this. They reach the AVD
// service over the internet to register, so a host on a private subnet with no
// NAT gateway and no firewall route never comes up — it builds, the extensions
// time out, and the deployment fails twenty minutes in or, worse, succeeds with
// a host nobody can connect to.
//
// Standalone topology makes this easy to get wrong, because there is no firewall
// route to fall back on: every VNet needs its own NAT gateway.
var spokesWithoutOutboundList = [
  for spoke in spokes: (routeViaFirewall || (spoke.natGateway && !empty(filter(
    subnets,
    s => s.spoke == spoke.name && s.useNatGateway
  )))) ? '' : spoke.name
]

var spokesWithoutOutbound = filter(spokesWithoutOutboundList, n => !empty(n))

// Whether the spoke the session hosts land in can actually reach the internet.
// They are skipped when it cannot, rather than built into a state where they
// can never register.
var avdSpokeHasOutbound = !hasAvdSpoke || !contains(spokesWithoutOutbound, avdSpokeName)

// Everything Entra depends on the bootstrap identity. Without it both
// deployment scripts are skipped and group object IDs have to be supplied by
// hand — the template still deploys, it just leaves more for you to do.
// Built rather than asked for: the identity is located by the name the bootstrap
// script gave it, in the subscription being deployed into.
var entraIdentityId = useEntraManagedIdentity
  ? resourceId(
      subscription().subscriptionId,
      entraManagedIdentityRgName,
      'Microsoft.ManagedIdentity/userAssignedIdentities',
      entraManagedIdentityName
    )
  : ''

var hasEntraIdentity = !empty(entraIdentityId)
var isEntraOnly = identityModel == 'entraOnly'

// Available under both identity models. The groups exist to carry Azure RBAC —
// Desktop Virtualization User on the application group, the SMB share roles on
// the storage account — and an Entra group holds synced users as happily as
// cloud-only ones, so those assignments work either way.
//
// The caveat, which matters only once session hosts exist: a group created here
// is cloud-only and cannot be managed from on-premises AD, and its SID is a
// cloud SID. File-level NTFS permissions on the share resolve group SIDs from
// the user's Kerberos ticket, which for a hybrid identity carries the SIDs of
// its AD groups. So for NTFS specifically, a synced AD group is the safer
// choice. Share-level access is unaffected.
var doCreateGroups = createEntraGroups && hasEntraIdentity

// Entra Kerberos needs identities that already exist and are synced. Under
// hybrid on a first pass neither is true, so both halves are deferred until
// the domain controller is in place.
var entraKerberosReady = isEntraOnly || hybridDomainControllerReady

var doEnableEntraKerberos = storageEnableEntraKerberos && entraKerberosReady
var doKerberosSetup = deployStorage && doEnableEntraKerberos && configureEntraKerberos && hasEntraIdentity

// Created groups take precedence over supplied ones, so the two can never
// disagree about which group is which.
var usersGroupObjectId = doCreateGroups ? entraGroups!.outputs.usersGroupObjectId : avdUsersGroupObjectId
var adminsGroupObjectId = doCreateGroups ? entraGroups!.outputs.adminsGroupObjectId : avdAdminsGroupObjectId

// NTFS permissions are set from the first session host of the first host pool.
// Any host with a route to the share would do; picking a fixed one keeps the
// step deterministic across redeployments.
//
// The condition deliberately tests avdUsersGroupObjectId rather than the
// resolved usersGroupObjectId: a module condition has to be decidable without
// waiting on another module's output.
var haveUsersGroup = doCreateGroups || !empty(avdUsersGroupObjectId)
var firstPoolHasHosts = !empty(hostPools) && sessionHostCounts[0] > 0
// The step mounts the share with the account key over the file endpoint, so it
// needs shared key access and a reachable endpoint — either the private one or
// the public one. Without both, the mount fails at the very last step of an
// otherwise successful deployment, which is a miserable way to find out.
var canMountShare = storageAllowSharedKeyAccess && (hasPeSubnet || storagePublicNetworkAccess == 'Enabled')

// Desktop names. AVD calls every published desktop "SessionDesktop"; a host
// pool row can override it with desktopFriendlyName. Rows that do not are left
// alone rather than renamed to their pool's friendly name, so the behaviour is
// explicit rather than surprising.
var desktopNameEntries = [
  for pool in hostPools: {
    applicationGroup: 'ag-${pool.name}-desktop'
    desktopName: string(pool.?desktopFriendlyName ?? '')
  }
]
var desktopsToRename = filter(desktopNameEntries, d => !empty(d.desktopName))
var doDesktopNames = setDesktopFriendlyNames && deployControlPlane && hasEntraIdentity && !empty(desktopsToRename)

// Cloud-only for now. The step resolves the users group by converting its Entra
// object ID into an S-1-12-1 cloud SID, which only exists for a cloud identity.
// A hybrid deployment's group has a domain SID instead and has to be resolved by
// its on-premises name, which this template does not ask for.
var doNtfsPermissions = setFslogixNtfsPermissions && isEntraOnly && deployStorage && deployControlPlane && deploySessionHosts && hasSessionHostSubnet && firstPoolHasHosts && haveUsersGroup && canMountShare

// The bootstrap identity, read so its principal ID can be given a role on the
// AVD resource group. Index 4 of the resource ID is the resource group name.
resource entraIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (hasEntraIdentity) {
  name: last(split(entraIdentityId, '/'))
  scope: resourceGroup(split(entraIdentityId, '/')[4])
}

//
// RESOURCE GROUPS — one per spoke
//
resource spokeRgs 'Microsoft.Resources/resourceGroups@2024-03-01' = [
  for spoke in spokes: if (isCreateNetwork) {
    name: spokeRgByName[spoke.name]
    location: location
    tags: allTags
  }
]

// In existing mode the network is somebody else's, but the AVD resources still
// need a home of their own.
resource avdRg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (!isCreateNetwork && !empty(avdRgName)) {
  name: avdRgName
  location: location
  tags: allTags
}

//
// NSGS — one per subnet, flat loop
//
module nsgs 'modules/nsg.bicep' = [
  for (s, i) in spokeSubnets: if (isCreateNetwork) {
    name: 'nsg-${s.spoke}-${s.name}'
    scope: resourceGroup(s.rgName)
    dependsOn: [
      spokeRgs
    ]
    params: {
      tags: allTags
      location: location
      nsgName: s.nsgName
      nsgType: s.nsgType
    }
  }
]

//
// ROUTE TABLES — one per spoke, only when the hub has a firewall
//
module routeTables 'modules/routeTable.bicep' = [
  for (spoke, i) in spokes: if (isCreateNetwork && routeViaFirewall) {
    name: 'rt-${spoke.name}'
    scope: resourceGroup(spokeRgByName[spoke.name])
    dependsOn: [
      spokeRgs
    ]
    params: {
      tags: allTags
      location: location
      routeTableName: 'rt-${spoke.name}'
      firewallInternalIp: trim(firewallPrivateIp)
    }
  }
]

//
// NAT GATEWAYS — one per spoke that asks for one
//
// A NAT gateway cannot be attached to subnets in more than one VNet, so
// spokes cannot share. Each one carries its own public IP and its own
// monthly cost, which is why this is opt-in per spoke.
//
module natGateways 'modules/natGateway.bicep' = [
  for (spoke, i) in spokes: if (isCreateNetwork && spoke.natGateway) {
    name: 'nat-${spoke.name}'
    scope: resourceGroup(spokeRgByName[spoke.name])
    dependsOn: [
      spokeRgs
    ]
    params: {
      tags: allTags
      location: location
      natGatewayName: 'nat-${spoke.name}'
      publicIpName: 'pip-nat-${spoke.name}'
    }
  }
]

//
// SPOKE VNETS
//
// Each spoke module receives only its own subnets, with the matching NSG
// and route table IDs already resolved. filter() selects this spoke's
// subnets; the index lookup into nsgs[] finds the NSG built for each.
//

// One list of DNS servers for every VNet, because in practice every VNet in a
// customer's estate resolves against the same domain controllers. A spoke can
// still carry its own dnsServers in a parameters file, and that wins.
//
// Typed as free text, comma or semicolon separated, because that is how people
// write a list of IPs.
//
// split() on an empty string returns [''] rather than [], so without the filter
// a spoke with no DNS servers would be handed one empty string and the VNet
// would be rejected. Blank entries from a trailing separator go the same way.
func parseDnsServers(value string) array =>
  filter(split(replace(trim(value), ';', ','), ','), s => !empty(trim(s)))

var defaultDnsServers = parseDnsServers(dnsServers)

var spokeDnsServers = [
  for spoke in spokes: empty(trim(string(spoke.?dnsServers ?? '')))
    ? defaultDnsServers
    : parseDnsServers(string(spoke.dnsServers))
]
module spokeVnets 'modules/spoke.bicep' = [
  for (spoke, si) in spokes: if (isCreateNetwork) {
    name: 'spoke-${spoke.name}'
    scope: resourceGroup(spokeRgByName[spoke.name])
    dependsOn: [
      spokeRgs
      nsgs
      routeTables
      natGateways
    ]
    params: {
      tags: allTags
      location: location
      spokeName: spoke.name
      vnetName: spokeVnetByName[spoke.name]
      addressPrefix: spoke.addressPrefix
      // filter() selects this spoke's subnets; map() reshapes them for the
      // module. NSGs are passed by name — see spoke.bicep for why.
      subnets: map(
        filter(spokeSubnets, s => s.spoke == spoke.name),
        s => {
          name: s.name
          prefix: s.prefix
          nsgName: s.nsgName
          useNatGateway: s.useNatGateway
          hostsPrivateEndpoints: s.hostsPrivateEndpoints
        }
      )
      routeTableName: routeViaFirewall ? 'rt-${spoke.name}' : ''
      natGatewayName: spoke.natGateway ? 'nat-${spoke.name}' : ''
      privateSubnets: privateSubnets
      // Per-spoke, because a hybrid deployment may want the AVD spoke pointed
      // at domain controllers while another spoke keeps Azure DNS.
      dnsServers: spokeDnsServers[si]
    }
  }
]

//
// PEERINGS — two per spoke that opts in
//
// Peering, to a hub that already exists.
//
// Both sides of a peering have to be created, and the hub side lives in the
// customer's own resource group. That is reachable only when the hub is in the
// same subscription as this deployment — a subscription-scoped template cannot
// deploy into another subscription. When it is elsewhere, only the spoke side
// is created and hubSidePeeringNotCreated says so: until their network team
// adds the matching peering, neither side carries traffic.
var hubVnetSubscriptionId = peerToHub ? split(trim(peerToExistingHubVnetId), '/')[2] : ''
var hubVnetRgName = peerToHub ? split(trim(peerToExistingHubVnetId), '/')[4] : ''
var canPeerHubSide = peerToHub && hubVnetSubscriptionId == subscription().subscriptionId

module hubToSpoke 'modules/peering.bicep' = [
  for (spoke, i) in spokes: if (canPeerHubSide && (spoke.?peerToHub ?? false)) {
    name: 'peer-hub-to-${spoke.name}'
    scope: resourceGroup(hubVnetRgName)
    params: {
      localVnetName: lastSegment(peerToExistingHubVnetId)
      remoteVnetId: spokeVnets[i]!.outputs.vnetId
      peeringName: 'hub-to-${spoke.name}'
      allowForwardedTraffic: true
      allowGatewayTransit: false
      useRemoteGateways: false
    }
  }
]

module spokeToHub 'modules/peering.bicep' = [
  for (spoke, i) in spokes: if (peerToHub && (spoke.?peerToHub ?? false)) {
    name: 'peer-${spoke.name}-to-hub'
    scope: resourceGroup(spokeRgByName[spoke.name])
    params: {
      localVnetName: spokeVnets[i]!.outputs.vnetName
      remoteVnetId: trim(peerToExistingHubVnetId)
      peeringName: '${spoke.name}-to-hub'
      // The hub may carry a firewall or a gateway; traffic forwarded from it is
      // dropped without this, and the symptom is a route that silently fails
      // rather than an error.
      allowForwardedTraffic: true
      allowGatewayTransit: false
      // Left false deliberately. A spoke using the hub's gateway is a decision
      // about the customer's connectivity, not something to turn on for them.
      useRemoteGateways: false
    }
  }
]

//
// ENTRA ID — access groups
//
// Deployed into the AVD resource group. The groups themselves are tenant
// objects and have nothing to do with it; the deployment script just needs
// somewhere to run.
//
module entraGroups 'modules/entraGroups.bicep' = if (doCreateGroups && !empty(avdRgName)) {
  name: 'entraGroups'
  scope: resourceGroup(avdRgName)
  dependsOn: [
    spokeRgs
    avdRg
  ]
  params: {
    tags: allTags
    location: location
    managedIdentityId: entraIdentityId
    usersGroupName: avdUsersGroupName
    adminsGroupName: avdAdminsGroupName
    azCliVersion: deploymentScriptAzCliVersion
    retainArtifacts: retainDeploymentScriptArtifacts
  }
}

//
// STORAGE
//
// One account shared across every host pool, in its own resource group.
//
resource storageRg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployStorage) {
  name: storageRgName
  location: location
  tags: allTags
}

module storage 'modules/storage.bicep' = if (deployStorage) {
  name: 'storage'
  scope: resourceGroup(storageRgName)
  dependsOn: [
    storageRg
  ]
  params: {
    tags: allTags
    location: location
    storageAccountName: storageAccountName
    storageSku: storageSku
    storageAccountKind: storageAccountKind
    storageAccessTier: storageAccessTier
    fileShareName: fileShareName
    fileShareQuotaGiB: fileShareQuotaGiB
    minimumTlsVersion: storageMinimumTlsVersion
    supportsHttpsTrafficOnly: storageSupportsHttpsTrafficOnly
    allowBlobPublicAccess: storageAllowBlobPublicAccess
    allowSharedKeyAccess: storageAllowSharedKeyAccess
    publicNetworkAccess: storagePublicNetworkAccess
    largeFileSharesState: storageLargeFileSharesState
    enableEntraKerberos: doEnableEntraKerberos
    defaultSharePermission: storageDefaultSharePermission
  }
}

// Admin consent and the cloud group SIDs tag on the application the Storage
// resource provider created. Both mandatory for cloud-only Entra Kerberos,
// neither expressible as an ARM resource.
module entraKerberos 'modules/storageEntraKerberos.bicep' = if (doKerberosSetup) {
  name: 'entraKerberos'
  scope: resourceGroup(storageRgName)
  dependsOn: [
    storage
  ]
  params: {
    tags: allTags
    location: location
    managedIdentityId: entraIdentityId
    storageAccountName: storageAccountName
    azCliVersion: deploymentScriptAzCliVersion
    retainArtifacts: retainDeploymentScriptArtifacts
    applyCloudGroupSidsTag: isEntraOnly
  }
}

// Private DNS zone, VNet links and the private endpoint. Only possible when
// a subnet has been flagged to host it.
module fslogixPrivateAccess 'modules/fslogixPrivateAccess.bicep' = if (deployStorage && hasPeSubnet) {
  name: 'fslogixPrivateAccess'
  scope: resourceGroup(storageRgName)
  dependsOn: [
    spokeVnets
  ]
  params: {
    tags: allTags
    location: location
    storageAccountId: storage!.outputs.storageAccountId
    privateEndpointSubnetId: peSubnetId
    privateEndpointName: fslogixPrivateEndpointName
    linkedVnets: dnsLinkedVnets
  }
}

module storageRbac 'modules/storageRbac.bicep' = if (deployStorage) {
  name: 'storageRbac'
  scope: resourceGroup(storageRgName)
  params: {
    storageAccountName: storage!.outputs.storageAccountName
    avdUsersGroupObjectId: usersGroupObjectId
    avdAdminsGroupObjectId: adminsGroupObjectId
  }
}

//
// MONITORING
//
resource monitoringRg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (deployMonitoring) {
  name: monitoringRgName
  location: location
  tags: allTags
}

module logAnalytics 'modules/logAnalytics.bicep' = if (deployMonitoring) {
  name: 'logAnalytics'
  scope: resourceGroup(monitoringRgName)
  dependsOn: [
    monitoringRg
  ]
  params: {
    tags: allTags
    location: location
    workspaceName: logAnalyticsWorkspaceName
    retentionInDays: logAnalyticsRetentionDays
    sku: logAnalyticsSku
  }
}

module spokeVnetDiagnostics 'modules/vnetDiagnostics.bicep' = [
  for (spoke, i) in spokes: if (deployMonitoring) {
    name: 'diag-${spoke.name}'
    scope: resourceGroup(spokeRgByName[spoke.name])
    dependsOn: [
      spokeVnets
    ]
    params: {
      vnetName: spokeVnetByName[spoke.name]
      workspaceId: logAnalytics!.outputs.workspaceId
    }
  }
]

module storageDiagnostics 'modules/storageDiagnostics.bicep' = if (deployMonitoring && deployStorage) {
  name: 'diag-storage'
  scope: resourceGroup(storageRgName)
  params: {
    storageAccountName: storage!.outputs.storageAccountName
    workspaceId: logAnalytics!.outputs.workspaceId
  }
}

// Session host telemetry for AVD Insights. The control plane half of Insights
// is the diagnostic settings already wired onto the host pool, application
// groups and workspace; this is the other half.
// Deployed next to the host pool, not with the rest of the monitoring.
//
// The AVD Insights configuration workbook lists the data collection rules in
// the HOST POOL's resource group by default. A rule sitting in the monitoring
// group is invisible to it, so the blade reports the session hosts as not
// configured and offers to create a second, competing rule. Tidy in principle,
// wrong in practice.
module avdInsights 'modules/avdInsightsDcr.bicep' = if (deployInsights && !empty(avdRgName)) {
  name: 'avdInsights'
  scope: resourceGroup(avdRgName)
  dependsOn: [
    spokeRgs
    avdRg
    monitoringRg
  ]
  params: {
    tags: allTags
    location: location
    logAnalyticsWorkspaceId: logAnalytics!.outputs.workspaceId
    // Referenced so the dependency survives any future reshuffle of dependsOn.
    requiredTables: logAnalytics!.outputs.builtInTables
    collectPerProcessInputDelay: collectPerProcessInputDelay
  }
}

// Action group and the starter alert set. The metric alerts are scoped to the
// AVD resource group rather than to named VMs, so hosts added or rebuilt later
// are covered without touching the template.
module avdAlerts 'modules/alerts.bicep' = if (deployAlertRules && hasAvdSpoke) {
  name: 'avdAlerts'
  scope: resourceGroup(monitoringRgName)
  dependsOn: [
    monitoringRg
    spokeRgs
  ]
  params: {
    tags: allTags
    location: location
    logAnalyticsWorkspaceId: logAnalytics!.outputs.workspaceId
    // Built by hand rather than with subscriptionResourceId(), which inserts a
    // /providers/ segment and produces something that looks like a resource
    // group ID but is not one. Azure Monitor validates the scope and rejects it.
    sessionHostResourceGroupId: '${subscription().id}/resourceGroups/${avdRgName}'
    sessionHostRegion: location
    alertEmailAddress: alertEmailAddress
    actionGroupShortName: alertActionGroupShortName
    cpuThresholdPercent: cpuAlertThresholdPercent
    memoryThresholdPercent: memoryAlertThresholdPercent
    diskFreeThresholdPercent: diskFreeAlertThresholdPercent
    deployMetricAlerts: deployControlPlane && deploySessionHosts
  }
}

//
// AVD CONTROL PLANE
//
// Host pool -> application group -> workspace. Each host pool gets its own
// desktop application group; the single workspace references all of them.
//
module avdHostPools 'modules/avdHostPool.bicep' = [
  for (pool, i) in hostPools: if (deployControlPlane) {
    name: 'hp-${pool.name}'
    scope: resourceGroup(avdRgName)
    dependsOn: [
      spokeRgs
    ]
    params: {
      tags: allTags
      location: location
      hostPoolName: 'hp-${pool.name}'
      friendlyName: pool.friendlyName
      maxSessionLimit: pool.maxSessionLimit
      startVMOnConnect: pool.startVMOnConnect
      registrationTokenExpiry: registrationTokenExpiry
      customRdpProperties: hostPoolCustomRdpProperties
      logAnalyticsWorkspaceId: avdDiagnosticsWorkspaceId
    }
  }
]

module avdApplicationGroups 'modules/avdApplicationGroup.bicep' = [
  for (pool, i) in hostPools: if (deployControlPlane) {
    name: 'ag-${pool.name}'
    scope: resourceGroup(avdRgName)
    params: {
      tags: allTags
      location: location
      applicationGroupName: 'ag-${pool.name}-desktop'
      friendlyName: pool.friendlyName
      hostPoolId: avdHostPools[i]!.outputs.hostPoolId
      // Assigning the users group here is what makes the desktop visible
      // in the client. Without it the deployment succeeds and nobody can
      // see anything.
      avdUsersGroupObjectId: usersGroupObjectId
      logAnalyticsWorkspaceId: avdDiagnosticsWorkspaceId
    }
  }
]

module avdWorkspace 'modules/avdWorkspace.bicep' = if (deployControlPlane) {
  name: 'avdWorkspace'
  scope: resourceGroup(avdRgName)
  params: {
    tags: allTags
    location: location
    workspaceName: avdWorkspaceName
    friendlyName: avdWorkspaceFriendlyName
    applicationGroupReferences: [
      for (pool, i) in hostPools: avdApplicationGroups[i]!.outputs.applicationGroupId
    ]
    logAnalyticsWorkspaceId: avdDiagnosticsWorkspaceId
  }
}

//
// SESSION HOSTS
//
// One module invocation per host pool, looping internally over that pool's
// sessionHostCount. The module reads the registration token itself, so the
// token never passes through a module output — it only has to exist first,
// which the dependsOn on avdHostPools guarantees.
//
// @batchSize(1) keeps pools building one at a time. Session host deployments
// are long and failure-prone (image availability, quota, extension timeouts),
// and serialising them makes a failure attributable to one pool.
//
@batchSize(1)
module sessionHosts 'modules/sessionHost.bicep' = [
  // isEntraOnly is part of the condition, not a separate guard: under hybrid this
  // template deliberately builds the landing zone and no session hosts, because
  // there is no domain controller for them to join.
  for (pool, i) in hostPools: if (deployControlPlane && deploySessionHosts && isEntraOnly && hasSessionHostSubnet && avdSpokeHasOutbound && sessionHostCounts[i] > 0) {
    name: 'sh-${pool.name}'
    scope: resourceGroup(avdRgName)
    dependsOn: [
      spokeVnets
      avdHostPools
      // The peerings matter as much as the route table. A session host subnet
      // carrying a default route to the firewall's private IP — which lives in
      // the HUB vnet — has no path to that next hop until the peering exists.
      // A VM booting into that window fails its Entra join silently.
      hubToSpoke
      spokeToHub
    ]
    params: {
      tags: allTags
      location: location
      hostPoolName: 'hp-${pool.name}'
      sessionHostCount: sessionHostCounts[i]
      vmSize: string(pool.?vmSize ?? 'Standard_D4ads_v5')
      vmNamePrefix: sessionHostPrefixes[i]
      subnetId: sessionHostSubnetId
      adminUsername: sessionHostAdminUsername
      adminPassword: sessionHostAdminPassword
      imagePublisher: sessionHostImagePublisher
      imageOffer: sessionHostImageOffer
      imageSku: sessionHostImageSku
      imageVersion: sessionHostImageVersion
      osDiskType: sessionHostOsDiskType
      osDiskSizeGB: sessionHostOsDiskSizeGB
      artifactsLocation: sessionHostArtifactsLocation
      timeZone: sessionHostTimeZone
      enableTimeZoneRedirection: enableTimeZoneRedirection
      enrolWithIntune: sessionHostEnrolWithIntune
      acceleratedNetworking: sessionHostAcceleratedNetworking
      dataCollectionRuleId: deployInsights ? avdInsights!.outputs.dcrId : ''
      configureFslogix: configureFslogixOnSessionHosts && deployStorage
      fslogixStorageAccountName: storageAccountName
      fslogixShareName: fileShareName
      fslogixProfileSizeMB: fslogixProfileSizeMB
      restartAfterFslogixConfiguration: restartSessionHostsAfterFslogix
    }
  }
]

// Sign-in rights on the session hosts themselves. Separate from the
// application group assignment: that one publishes the desktop, this one lets
// the user actually log on to the VM behind it.
// Only for Entra-joined hosts. On a domain-joined host sign-in is an Active
// Directory matter and these roles grant nothing — assigning them would just
// leave misleading IAM entries for an admin to puzzle over later.
module sessionHostLogin 'modules/sessionHostLogin.bicep' = if (deployControlPlane && isEntraOnly) {
  name: 'sessionHostLogin'
  scope: resourceGroup(avdRgName)
  dependsOn: [
    spokeRgs
  ]
  params: {
    avdUsersGroupObjectId: usersGroupObjectId
    avdAdminsGroupObjectId: adminsGroupObjectId
  }
}

// NTFS permissions on the share root. Runs last, because it needs a session
// host that can reach the share and a users group to grant rights to.
module fslogixNtfs 'modules/fslogixNtfsPermissions.bicep' = if (doNtfsPermissions) {
  name: 'fslogixNtfsPermissions'
  scope: resourceGroup(avdRgName)
  dependsOn: [
    storage
    fslogixPrivateAccess
  ]
  params: {
    location: location
    // Taken from the module rather than rebuilt here, so that raising
    // startIndex later cannot point this at a VM that does not exist.
    vmName: sessionHosts[0]!.outputs.firstVmName
    storageAccountName: storageAccountName
    storageRgName: storageRgName
    fileShareName: fileShareName
    avdUsersGroupObjectId: usersGroupObjectId
  }
}

//
// OUTPUTS
//
@description('Resource IDs of the VNets this deployment created. Empty when networkMode is existing.')
output createdVnetIds array = [for (spoke, i) in spokes: isCreateNetwork ? spokeVnets[i]!.outputs.vnetId : '']

@description('The network mode this deployment used.')
output networkModeUsed string = networkMode

@description('''True when a hub VNet was given to peer to but it is in another
subscription, so only the spoke side of each peering was created. Both sides must exist
before traffic flows: their network team adds the matching peering on the hub, or this
template is deployed into their subscription instead.''')
output hubSidePeeringNotCreated bool = peerToHub && !canPeerHubSide

@description('''Spokes with no outbound internet path — no hub firewall route and no
NAT gateway attached to any of their subnets. Empty is what you want. A non-empty
list does NOT fail the deployment: it succeeds and the VMs simply cannot reach the
internet, which for an AVD spoke means session hosts that never register. Check
this before deploying.''')
output spokesWithoutOutbound array = spokesWithoutOutbound

@description('Resource ID of the FSLogix storage account, empty when storage is not deployed.')
output storageAccountId string = deployStorage ? storage!.outputs.storageAccountId : ''

@description('Resource ID of the Log Analytics workspace, empty when monitoring is not deployed.')
output logAnalyticsWorkspaceId string = deployMonitoring ? logAnalytics!.outputs.workspaceId : ''

@description('''True when storage was requested but no subnet was flagged with
hostsPrivateEndpoints, so the share has no private endpoint and is reachable only
over its public endpoint. Flag only — the deployment still succeeds.''')
output storageHasNoPrivateEndpoint bool = deployStorage && !hasPeSubnet

@description('''Resource group names produced by a spoke that clash with the hub,
storage or monitoring resource group. Empty is what you want. A clash means two
parts of the deployment target the same resource group — rename the spoke or the
shared group.''')
output resourceGroupNameCollisions array = rgNameCollisions

@description('''True when host pools were defined but no spoke has role 'avd', so the
control plane has no resource group to live in and was skipped entirely. Set a
spoke's role to 'avd' to fix.''')
output hostPoolsSkippedNoAvdSpoke bool = !empty(hostPools) && !hasAvdSpoke

@description('Resource ID of the AVD workspace, empty when no control plane was deployed.')
output avdWorkspaceId string = deployControlPlane ? avdWorkspace!.outputs.workspaceId : ''

@description('''Names of the host pools created. Fetch a registration token with:
az desktopvirtualization hostpool retrieve-registration-token --resource-group <rg> --host-pool-name <name>''')
output hostPoolNames array = deployControlPlane ? hostPoolNameList : []

@description('''True when session hosts were requested but the AVD spoke has no subnet
with nsgType \'avd\' to put them in, so they were skipped. The control plane still
deployed — you have host pools with no hosts. Set nsgType to \'avd\' on the session
host subnet and redeploy.''')
output sessionHostsSkippedNoSubnet bool = anySessionHostsRequested && !hasSessionHostSubnet

@description('''True when two host pools produce the same session host VM name prefix,
because their names agree in the first 11 characters once lowercased and stripped of
hyphens. The second pool\'s VMs would collide with the first\'s. Set vmNamePrefix
explicitly on one of them.''')
output duplicateSessionHostPrefixes bool = length(sessionHostPrefixes) != length(union(
  sessionHostPrefixes,
  []
))

@description('Total number of session hosts this deployment created across all pools.')
output sessionHostCount int = (deployControlPlane && hasSessionHostSubnet) ? totalSessionHosts : 0

@description('Name of the subnet session hosts were placed in, empty when none was found.')
output sessionHostSubnet string = sessionHostSubnetName

@description('Object ID of the AVD users group, whether created here or supplied.')
output avdUsersGroupId string = usersGroupObjectId

@description('Object ID of the AVD admins group, whether created here or supplied.')
output avdAdminsGroupId string = adminsGroupObjectId

@description('''Application (client) ID of the storage account\'s Entra application.
THE ONE REMAINING MANUAL STEP: exclude this application from any Conditional Access
policy that requires MFA. Entra Kerberos does not support MFA, and a broad
"require MFA for all apps" policy produces "System error 1327" when users try to load
their profile. Empty when the Entra Kerberos setup did not run.''')
output storageEntraApplicationId string = doKerberosSetup ? entraKerberos!.outputs.applicationId : ''

@description('''True when Entra work was requested but no managed identity was supplied,
so group creation and the Entra Kerberos setup were both skipped. The deployment still
succeeds; the share will not authenticate until those steps are done by hand. Run
scripts/bootstrap-entra-identity.ps1 and redeploy.''')
output entraWorkSkippedNoIdentity bool = (createEntraGroups || (configureEntraKerberos && deployStorage && doEnableEntraKerberos)) && !hasEntraIdentity

@description('''True when the Entra Kerberos setup was deferred because identityModel is
hybrid and the domain controller is not in place yet. The storage account has no AADKERB
and no admin consent was granted, so profiles will not mount until you build the domain
controller, get Entra Connect syncing, and redeploy with hybridDomainControllerReady
ticked. This is the intended first-pass state, not a failure.''')
output entraKerberosDeferred bool = !entraKerberosReady && deployStorage && storageEnableEntraKerberos

@description('''True when NTFS permissions were requested but could not be set, because
there is no session host to run from or no users group to grant rights to. Until they
are set, every user can read every other user\'s profile.''')
output fslogixNtfsPermissionsSkipped bool = setFslogixNtfsPermissions && deployStorage && !doNtfsPermissions

//
// HYBRID PREFLIGHT
//
// Each of these is a way a hybrid deployment fails hours after it appears to
// have succeeded, so they are reported rather than left to be discovered.
//
@description('The identity model this deployment was built for.')
output identityModelUsed string = identityModel

@description('''True when identityModel is hybrid and no group object IDs were supplied.
Hybrid deployments cannot create their own groups — the groups live in Active Directory
and sync upward — so nobody is granted access to the desktop or the share.''')
output hybridMissingGroupObjectIds bool = !isEntraOnly && (empty(avdUsersGroupObjectId) || empty(avdAdminsGroupObjectId))

@description('''True when identityModel is hybrid, so session hosts were not created.
This is by design: there is no domain controller to join them to yet. Host pools,
application groups and the workspace are created and left empty. NTFS permissions on
the share root are skipped with them, and will need setting with icacls from the first
host once it exists.''')
output hybridSessionHostsSkipped bool = !isEntraOnly && deploySessionHosts

@description('''True when desktop friendly names were set on host pool rows but no
managed identity was supplied, so the desktops are all still called SessionDesktop.
The rename needs a REST call, which needs the identity.''')
output desktopNamesSkippedNoIdentity bool = setDesktopFriendlyNames && !empty(desktopsToRename) && !hasEntraIdentity

@description('''True when alerts were deployed with no email address, so they fire and
appear in the portal but nobody is notified. Harmless if that is deliberate.''')
output alertsHaveNoRecipient bool = (deployAlertRules && hasAvdSpoke) ? avdAlerts!.outputs.actionGroupHasNoReceiver : false

@description('''True when AVD Insights was requested but monitoring is off, so there is
no workspace for session host telemetry to go to and the agent was not installed.''')
output insightsSkippedNoWorkspace bool = deployAvdInsights && !deployMonitoring

@description('''True when the FSLogix storage account is still in its bootstrap posture:
shared key access enabled, or the public endpoint still open.

Both are needed during deployment — the NTFS step mounts the share with the account key,
and the control plane creates the share over the public endpoint. Neither should survive
into steady state. Once a client has mounted the share successfully, redeploy with
storageAllowSharedKeyAccess false and storagePublicNetworkAccess Disabled.

This output exists because the alternative is someone seeing a green deployment and
never coming back to harden it.''')
output storageHardeningRequired bool = deployStorage && (storageAllowSharedKeyAccess || storagePublicNetworkAccess == 'Enabled')

@description('''Subnets whose parent spoke name matches no spoke. Each one targets a
resource group that will never exist, and the deployment fails with
ResourceGroupNotFound naming that group rather than the mismatch that caused it.

Empty is what you want. A non-empty list means the Subnets tab and the Spokes tab
disagree about a name.''')
output subnetsWithUnknownSpoke array = [for s in orphanedSubnets: '${s.name} (parent: ${s.spoke})']
