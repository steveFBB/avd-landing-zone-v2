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
// HUB
//
param hubRgName string
param hubVnetName string
param hubAddressPrefix string
param gatewaySubnetPrefix string

@description('''Hub firewall. Drives three things at once so they cannot drift apart:
the hub subnets, the spoke route tables, and whether peerings allow forwarded traffic.

  none           no firewall. Spokes need a NAT gateway for outbound internet.
  fortigate      four FortiGate NIC subnets for an appliance you deploy yourself.
                 hubFirewallInternalIp is then required, because the template has no
                 way to know it.
  azureFirewall  deploys the firewall, a policy carrying the documented AVD egress
                 rules, and its public IP. The private IP is read from the resource, so
                 hubFirewallInternalIp is not used.''')
@allowed([
  'none'
  'fortigate'
  'azureFirewall'
])
param hubFirewallType string

@description('Internal IP of the hub firewall NVA. Required when hubFirewallType is not \'none\'. Must sit inside fgtInternalPrefix.')
param hubFirewallInternalIp string = ''

param fgtExternalPrefix string = ''
param fgtInternalPrefix string = ''
param fgtHaPrefix string = ''
param fgtMgmtPrefix string = ''

@description('''Azure Firewall tier.

Basic is not simply a cheaper Standard: it needs a management subnet and a second public
IP, it cannot filter by FQDN in network rules, and it tops out at 250 Mbps — a real
ceiling for a pooled AVD estate. Offered, but Standard is the sensible default.''')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param azureFirewallTier string = 'Standard'

@description('Prefix for AzureFirewallSubnet. Name fixed by Azure, /26 or larger. Required when hubFirewallType is azureFirewall.')
param azureFirewallSubnetPrefix string = ''

@description('Prefix for AzureFirewallManagementSubnet, /26 or larger. Required only on the Basic tier, where the management NIC is mandatory.')
param azureFirewallManagementSubnetPrefix string = ''

@description('Availability zones for the firewall. Empty deploys it regional.')
param azureFirewallZones array = []

@description('Create AzureBastionSubnet in the hub. Subnet only — no Bastion host is deployed.')
param deployBastionSubnet bool = false

@description('Prefix for AzureBastionSubnet. Azure requires /26 or larger.')
param bastionSubnetPrefix string = ''

//
// SPOKES
//
@description('''Spokes to create. One row per spoke in the GUI.
Each entry: {
  name          string  short name, e.g. 'avd' — drives all derived names
  addressPrefix string  e.g. '10.3.0.0/16'
  role          string  'avd' (hosts session hosts and the storage private
                        endpoint) or 'none'
  peerToHub     bool    create hub<->spoke peerings in both directions
  natGateway    bool    create a NAT gateway + public IP in this spoke.
                        Costs money per spoke — a NAT gateway cannot be
                        shared across VNets. Which subnets actually use it
                        is set per subnet below.
}''')
param spokes array

@description('''Subnets, matched to their parent spoke by the `spoke` field.
Each entry: {
  spoke                 string  must match a spokes[].name
  name                  string  short name — becomes snet-<spoke>-<name>
  prefix                string  e.g. '10.3.0.0/24'
  nsgType               string  'avd' (documented AVD outbound allow rules)
                                or 'empty'
  useNatGateway         bool    attach to the spoke's NAT gateway. Ignored
                                when the spoke has natGateway = false.
  hostsPrivateEndpoints bool    the FSLogix private endpoint lands here, and
                                this subnet gets private endpoint network
                                policies disabled. Exactly one subnet in the
                                AVD spoke should have this set.
}''')
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
// ENTRA ID
//
@description('''Resource ID of a user-assigned managed identity holding Graph
permissions, created once per tenant by scripts/bootstrap-entra-identity.ps1.

This exists because the Azure portal's deployment flow carries no Microsoft Graph
token, so a template deployed from a Create blade cannot create groups or finish the
Entra Kerberos setup on its own. A deployment script running as this identity can.

Leave empty to skip all Entra work and supply group object IDs by hand instead.''')
param entraManagedIdentityId string = ''

@description('''Create the AVD access groups rather than taking their object IDs as
parameters. Requires entraManagedIdentityId. The groups are matched by display name, so
redeploying reuses the existing ones instead of creating duplicates.''')
param createEntraGroups bool = false

@description('Display name for the AVD users group when createEntraGroups is true.')
param avdUsersGroupName string = 'AVD Users'

@description('Display name for the AVD admins group when createEntraGroups is true.')
param avdAdminsGroupName string = 'AVD Admins'

@description('''Grant admin consent and apply the kdc_enable_cloud_group_sids tag to the
application the Storage resource provider creates for the account. Both are mandatory
for cloud-only Entra Kerberos and neither can be expressed as an ARM resource. Requires
entraManagedIdentityId.''')
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
    managedIdentityId: entraManagedIdentityId
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
entraManagedIdentityId, and grants it Desktop Virtualization Application Group
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

var hubHasFirewall = hubFirewallType != 'none'
var deployAzureFirewall = hubFirewallType == 'azureFirewall'

// The route tables need the firewall's internal IP. With FortiGate it is a
// parameter, because the template does not deploy the appliance and cannot
// know it; with Azure Firewall it is read from the resource, which removes a
// whole class of transcription error.
var firewallInternalIp = deployAzureFirewall ? azureFirewall!.outputs.privateIp : hubFirewallInternalIp

// Everything that may egress through the firewall. Spokes only — the hub's own
// subnets do not route through it.
var spokeAddressPrefixes = [for spoke in spokes: spoke.addressPrefix]

var deployInsights = deployAvdInsights && deployMonitoring
var deployAlertRules = deployAlerts && deployMonitoring

// NVA-forwarded traffic must be allowed across peerings in both directions,
// or the firewall's forwarded spoke-to-spoke traffic is dropped at the
// peering rather than reaching the destination spoke.
var peeringAllowForwardedTraffic = hubHasFirewall

// Flatten spokes x their subnets into one list so NSGs (which are per
// subnet) can be created in a single flat loop. Bicep handles one flat
// loop far better than a nested one.
var spokeSubnets = [
  for subnet in subnets: {
    spoke: subnet.spoke
    name: subnet.name
    prefix: subnet.prefix
    nsgType: subnet.nsgType
    useNatGateway: subnet.useNatGateway
    hostsPrivateEndpoints: subnet.hostsPrivateEndpoints
    nsgName: 'nsg-${subnet.spoke}-${subnet.name}'
    rgName: 'rg-${subnet.spoke}'
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
var hasAvdSpoke = !empty(avdSpokes)
var avdSpokeName = hasAvdSpoke ? first(avdSpokes).name : ''

var peSubnets = filter(subnets, s => s.spoke == avdSpokeName && s.hostsPrivateEndpoints)
var hasPeSubnet = hasAvdSpoke && !empty(peSubnets)
var peSubnetName = hasPeSubnet ? first(peSubnets).name : ''

var peSubnetId = hasPeSubnet
  ? resourceId(
      subscription().subscriptionId,
      'rg-${avdSpokeName}',
      'Microsoft.Network/virtualNetworks/subnets',
      'vnet-${avdSpokeName}',
      'snet-${avdSpokeName}-${peSubnetName}'
    )
  : ''

// Every VNet that must resolve the FSLogix share: the hub plus all spokes.
// Linking a VNet to a private DNS zone costs nothing, so there is no reason
// to be selective here.
// A for-expression can only be the direct value of a declaration, not an
// argument to a function, so the spoke list is built separately and then
// concatenated.
var spokeVnetLinks = [
  for spoke in spokes: {
    name: 'vnet-${spoke.name}'
    id: resourceId(
      subscription().subscriptionId,
      'rg-${spoke.name}',
      'Microsoft.Network/virtualNetworks',
      'vnet-${spoke.name}'
    )
  }
]

var hubVnetLink = [
  {
    name: hubVnetName
    id: resourceId(
      subscription().subscriptionId,
      hubRgName,
      'Microsoft.Network/virtualNetworks',
      hubVnetName
    )
  }
]

var dnsLinkedVnets = concat(hubVnetLink, spokeVnetLinks)

// Spokes derive rg-<name>, so a spoke called 'storage' or 'mgmt' would
// collide with the shared resource groups and the two deployments would
// fight over the same RG.
var sharedRgNames = union(
  deployStorage ? [storageRgName] : [],
  deployMonitoring ? [monitoringRgName] : [],
  [hubRgName]
)
var spokeNames = [for spoke in spokes: spoke.name]

// A subnet whose parent spoke does not exist is deployed into rg-<that name>,
// which does not exist either — and the deployment fails several modules deep
// with ResourceGroupNotFound, pointing at a resource group rather than at the
// typo that caused it.
var orphanedSubnets = filter(subnets, s => !contains(spokeNames, s.spoke))

var spokeRgNames = [for spoke in spokes: 'rg-${spoke.name}']
var rgNameCollisions = filter(spokeRgNames, r => contains(sharedRgNames, r))

// The control plane lives in the AVD spoke's resource group, so it needs an
// AVD spoke to exist. Host pools defined without one are skipped rather
// than deployed somewhere arbitrary.
var deployControlPlane = hasAvdSpoke && !empty(hostPools)
var avdRgName = 'rg-${avdSpokeName}'
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
var avdHostSubnets = filter(subnets, s => s.spoke == avdSpokeName && s.nsgType == 'avd')
var hasSessionHostSubnet = hasAvdSpoke && !empty(avdHostSubnets)
var sessionHostSubnetName = hasSessionHostSubnet ? first(avdHostSubnets).name : ''

var sessionHostSubnetId = hasSessionHostSubnet
  ? resourceId(
      subscription().subscriptionId,
      avdRgName,
      'Microsoft.Network/virtualNetworks/subnets',
      'vnet-${avdSpokeName}',
      'snet-${avdSpokeName}-${sessionHostSubnetName}'
    )
  : ''

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
var spokesWithoutOutboundList = [
  for spoke in spokes: (hubHasFirewall || (spoke.natGateway && !empty(filter(
    subnets,
    s => s.spoke == spoke.name && s.useNatGateway
  )))) ? '' : spoke.name
]

// Everything Entra depends on the bootstrap identity. Without it both
// deployment scripts are skipped and group object IDs have to be supplied by
// hand — the template still deploys, it just leaves more for you to do.
var hasEntraIdentity = !empty(entraManagedIdentityId)
var doCreateGroups = createEntraGroups && hasEntraIdentity
var doKerberosSetup = deployStorage && storageEnableEntraKerberos && configureEntraKerberos && hasEntraIdentity

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

var doNtfsPermissions = setFslogixNtfsPermissions && deployStorage && deployControlPlane && deploySessionHosts && hasSessionHostSubnet && firstPoolHasHosts && haveUsersGroup && canMountShare

// The bootstrap identity, read so its principal ID can be given a role on the
// AVD resource group. Index 4 of the resource ID is the resource group name.
resource entraIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = if (hasEntraIdentity) {
  name: last(split(entraManagedIdentityId, '/'))
  scope: resourceGroup(split(entraManagedIdentityId, '/')[4])
}

//
// RESOURCE GROUPS — one per spoke
//
resource hubRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: hubRgName
  location: location
  tags: allTags
}

resource spokeRgs 'Microsoft.Resources/resourceGroups@2024-03-01' = [
  for spoke in spokes: {
    name: 'rg-${spoke.name}'
    location: location
  }
]

//
// HUB VNET
//
module hub 'modules/hub.bicep' = {
  name: 'hub'
  scope: hubRg
  params: {
    tags: allTags
    location: location
    vnetName: hubVnetName
    addressPrefix: hubAddressPrefix
    gatewaySubnetPrefix: gatewaySubnetPrefix
    firewallType: hubFirewallType
    fgtExternalPrefix: fgtExternalPrefix
    fgtInternalPrefix: fgtInternalPrefix
    fgtHaPrefix: fgtHaPrefix
    fgtMgmtPrefix: fgtMgmtPrefix
    deployBastionSubnet: deployBastionSubnet
    bastionSubnetPrefix: bastionSubnetPrefix
    azureFirewallSubnetPrefix: azureFirewallSubnetPrefix
    azureFirewallManagementSubnetPrefix: azureFirewallManagementSubnetPrefix
    azureFirewallTier: azureFirewallTier
  }
}

//
// AZURE FIREWALL
//
// Deployed into the hub resource group. The module chains its own rule
// collection group ahead of the firewall, and the spoke route tables below
// depend on this module — so a spoke's default route is never pointed at a
// firewall that has no rules yet. Session hosts Entra join on first boot, and
// that join going through an unconfigured firewall is a silent failure.
//
module azureFirewall 'modules/azureFirewall.bicep' = if (deployAzureFirewall) {
  name: 'azureFirewall'
  scope: hubRg
  params: {
    tags: allTags
    location: location
    firewallName: 'afw-hub'
    policyName: 'afwp-hub'
    tier: azureFirewallTier
    hubVnetId: hub.outputs.vnetId
    allowedSourceAddresses: spokeAddressPrefixes
    logAnalyticsWorkspaceId: deployMonitoring ? logAnalytics!.outputs.workspaceId : ''
    availabilityZones: azureFirewallZones
    allowIntuneEnrolment: sessionHostEnrolWithIntune
  }
}

//
// NSGS — one per subnet, flat loop
//
module nsgs 'modules/nsg.bicep' = [
  for (s, i) in spokeSubnets: {
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
  for (spoke, i) in spokes: if (hubHasFirewall) {
    name: 'rt-${spoke.name}'
    scope: resourceGroup('rg-${spoke.name}')
    dependsOn: [
      spokeRgs
    ]
    params: {
      tags: allTags
      location: location
      routeTableName: 'rt-${spoke.name}'
      firewallInternalIp: firewallInternalIp
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
  for (spoke, i) in spokes: if (spoke.natGateway) {
    name: 'nat-${spoke.name}'
    scope: resourceGroup('rg-${spoke.name}')
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
module spokeVnets 'modules/spoke.bicep' = [
  for (spoke, si) in spokes: {
    name: 'spoke-${spoke.name}'
    scope: resourceGroup('rg-${spoke.name}')
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
      routeTableName: hubHasFirewall ? 'rt-${spoke.name}' : ''
      natGatewayName: spoke.natGateway ? 'nat-${spoke.name}' : ''
      privateSubnets: privateSubnets
    }
  }
]

//
// PEERINGS — two per spoke that opts in
//
module hubToSpoke 'modules/peering.bicep' = [
  for (spoke, i) in spokes: if (spoke.peerToHub) {
    name: 'peer-hub-to-${spoke.name}'
    scope: hubRg
    params: {
      localVnetName: hubVnetName
      remoteVnetId: spokeVnets[i].outputs.vnetId
      peeringName: 'hub-to-${spoke.name}'
      allowForwardedTraffic: peeringAllowForwardedTraffic
      allowGatewayTransit: false
      useRemoteGateways: false
    }
  }
]

module spokeToHub 'modules/peering.bicep' = [
  for (spoke, i) in spokes: if (spoke.peerToHub) {
    name: 'peer-${spoke.name}-to-hub'
    scope: resourceGroup('rg-${spoke.name}')
    params: {
      localVnetName: spokeVnets[i].outputs.vnetName
      remoteVnetId: hub.outputs.vnetId
      peeringName: '${spoke.name}-to-hub'
      allowForwardedTraffic: peeringAllowForwardedTraffic
      allowGatewayTransit: false
      useRemoteGateways: false
    }
  }
]

//
// ENTRA ID — access groups
//
// Deployed into the hub resource group because it is the one group that always
// exists. The groups themselves are tenant objects and have nothing to do with
// that resource group; the deployment script just needs somewhere to run.
//
module entraGroups 'modules/entraGroups.bicep' = if (doCreateGroups) {
  name: 'entraGroups'
  scope: hubRg
  params: {
    tags: allTags
    location: location
    managedIdentityId: entraManagedIdentityId
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
    enableEntraKerberos: storageEnableEntraKerberos
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
    managedIdentityId: entraManagedIdentityId
    storageAccountName: storageAccountName
    azCliVersion: deploymentScriptAzCliVersion
    retainArtifacts: retainDeploymentScriptArtifacts
  }
}

// Private DNS zone, VNet links and the private endpoint. Only possible when
// a subnet has been flagged to host it.
module fslogixPrivateAccess 'modules/fslogixPrivateAccess.bicep' = if (deployStorage && hasPeSubnet) {
  name: 'fslogixPrivateAccess'
  scope: resourceGroup(storageRgName)
  dependsOn: [
    spokeVnets
    hub
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

module hubVnetDiagnostics 'modules/vnetDiagnostics.bicep' = if (deployMonitoring) {
  name: 'diag-hub'
  scope: hubRg
  dependsOn: [
    hub
  ]
  params: {
    vnetName: hubVnetName
    workspaceId: logAnalytics!.outputs.workspaceId
  }
}

module spokeVnetDiagnostics 'modules/vnetDiagnostics.bicep' = [
  for (spoke, i) in spokes: if (deployMonitoring) {
    name: 'diag-${spoke.name}'
    scope: resourceGroup('rg-${spoke.name}')
    dependsOn: [
      spokeVnets
    ]
    params: {
      vnetName: 'vnet-${spoke.name}'
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
module avdInsights 'modules/avdInsightsDcr.bicep' = if (deployInsights) {
  name: 'avdInsights'
  scope: resourceGroup(monitoringRgName)
  dependsOn: [
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
  for (pool, i) in hostPools: if (deployControlPlane && deploySessionHosts && hasSessionHostSubnet && sessionHostCounts[i] > 0) {
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
module sessionHostLogin 'modules/sessionHostLogin.bicep' = if (deployControlPlane) {
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
output hubVnetId string = hub.outputs.vnetId
output spokeVnetIds array = [for (spoke, i) in spokes: spokeVnets[i].outputs.vnetId]

// false means bastionSubnetPrefix is smaller than /26, which Azure rejects.
output bastionPrefixValid bool = hub.outputs.bastionPrefixValid

@description('''Spokes with no outbound internet path — no hub firewall route and no
NAT gateway attached to any of their subnets. Empty is what you want. A non-empty
list does NOT fail the deployment: it succeeds and the VMs simply cannot reach the
internet, which for an AVD spoke means session hosts that never register. Check
this before deploying.''')
output spokesWithoutOutbound array = filter(spokesWithoutOutboundList, s => !empty(s))

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
output entraWorkSkippedNoIdentity bool = (createEntraGroups || (configureEntraKerberos && deployStorage && storageEnableEntraKerberos)) && !hasEntraIdentity

@description('''True when NTFS permissions were requested but could not be set, because
there is no session host to run from or no users group to grant rights to. Until they
are set, every user can read every other user\'s profile.''')
output fslogixNtfsPermissionsSkipped bool = setFslogixNtfsPermissions && deployStorage && !doNtfsPermissions

@description('''True when desktop friendly names were set on host pool rows but no
managed identity was supplied, so the desktops are all still called SessionDesktop.
The rename needs a REST call, which needs the identity.''')
output desktopNamesSkippedNoIdentity bool = setDesktopFriendlyNames && !empty(desktopsToRename) && !hasEntraIdentity

@description('''False when AzureFirewallSubnet is smaller than /26, which Azure rejects.
Only meaningful when hubFirewallType is azureFirewall.''')
output azureFirewallPrefixValid bool = hub.outputs.azureFirewallPrefixValid

@description('''False when AzureFirewallManagementSubnet is smaller than /26. Only
meaningful on the Basic tier, which requires that subnet.''')
output azureFirewallMgmtPrefixValid bool = hub.outputs.azureFirewallMgmtPrefixValid

@description('Private IP of the Azure Firewall, which the spoke route tables point at. Empty when no Azure Firewall was deployed.')
output azureFirewallPrivateIp string = deployAzureFirewall ? azureFirewall!.outputs.privateIp : ''

@description('Public IP of the Azure Firewall — the address spoke traffic egresses from.')
output azureFirewallPublicIp string = deployAzureFirewall ? azureFirewall!.outputs.publicIp : ''

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
