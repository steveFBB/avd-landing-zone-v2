// =============================================================================
// AVD landing zone - v2 parameters
// =============================================================================
// Copy per customer and edit. Real customer files are gitignored.
//
// IDENTITY MODEL: CLOUD-ONLY. FSLogix storage uses Microsoft Entra Kerberos
// with cloud-only identities - no domain controller, no custom VNet DNS, no
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

// Applied to every resource that supports tags, and to the resource groups.
// The wizard collects these as a grid and passes them as tagPairs instead;
// the two are merged, so neither path discards the other.
param tags = {
  // Environment: 'Production'
  // CostCentre: '1234'
  // ManagedBy: 'TPx'
}

// -----------------------------------------------------------------------------
// NETWORK
// -----------------------------------------------------------------------------

// 'create'   builds the VNets from the spokes and subnets below.
// 'existing' uses VNets that already exist: point at the subnets instead and
//            nothing network-shaped is created.
//
// This template never creates a hub. A hub carries the customer's gateway,
// firewall and domain controllers and belongs to whoever runs their network;
// an AVD workload peers into it.
param networkMode = 'create'

// Only used when networkMode = 'existing'.
param existingSessionHostSubnetId = ''
param existingPrivateEndpointSubnetId = ''
param avdResourceGroupName = ''

// Whether there is a hub, and where it comes from. Only applies when
// networkMode = 'create'.
//   'none'     no hub; the VNets stand on their own.
//   'create'   build one here, with a gateway subnet and optionally a firewall,
//              an identity subnet for domain controllers and a Bastion subnet.
//   'existing' peer to one that already exists.
//
// Microsoft's model is only the third. A hub carries the customer's gateway,
// firewall and domain controllers, so creating one means owning part of their
// network design - right for a greenfield site, questionable where they already
// have Azure.
param hubMode = 'none'

// Only used when hubMode = 'existing'. Every spoke with peerToHub = true is
// peered to this VNet. The hub side of the peering is created only when the hub
// is in this same subscription; otherwise the customer's network team adds it.
param peerToExistingHubVnetId = ''

// Everything below is only used when hubMode = 'create'.
param hubRgName = 'rg-hub'
param hubVnetName = 'vnet-hub'
param hubAddressPrefix = '10.0.0.0/16'
param gatewaySubnetPrefix = '10.0.0.0/27'

// Subnet for domain controllers, added after the landing zone. Empty creates
// none. A hybrid deployment needs it.
param identitySubnetName = 'snet-identity'
param identitySubnetPrefix = ''

// AzureBastionSubnet. The name is fixed by Azure and /26 is the minimum.
// Creates the subnet only; no Bastion host is deployed.
param deployBastionSubnet = false
param bastionSubnetPrefix = ''

// Firewall in the created hub. Selecting one makes it the egress path for every
// created VNet, overriding egressMode.
//   'azureFirewall' deploys the firewall and a policy carrying the documented
//                   AVD egress rules; its private IP is read from the resource.
//   'fortigate'     creates the four NIC subnets only. The appliance, its
//                   licensing and its HA pairing are yours, and
//                   hubFirewallInternalIp has to be supplied by hand.
param hubFirewallType = 'none'

// Required when hubFirewallType = 'fortigate'. Must sit inside fgtInternalPrefix.
param hubFirewallInternalIp = ''
param fgtExternalPrefix = ''
param fgtInternalPrefix = ''
param fgtHaPrefix = ''
param fgtMgmtPrefix = ''

// Only used when hubFirewallType = 'azureFirewall'. Basic tops out at 250 Mbps
// and requires the management subnet with a second public IP, unconditionally.
param azureFirewallTier = 'Standard'
param azureFirewallSubnetPrefix = ''
param azureFirewallManagementSubnetPrefix = ''
param azureFirewallZones = []

// How VMs reach the internet.
//   'natGateway' a NAT gateway per spoke that asks for one. Microsoft's
//                recommendation for AVD: predictable outbound addresses with no
//                inspection device in the path of the service traffic.
//   'firewall'   a default route to a firewall that already exists.
//   'none'       neither.
//
// Session hosts reach the AVD service over the internet to register, so a host
// with no egress never comes up.
param egressMode = 'natGateway'

// Required when egressMode = 'firewall'.
param firewallPrivateIp = ''

// -----------------------------------------------------------------------------
// SPOKES
// -----------------------------------------------------------------------------
// Add or remove entries freely. Each spoke gets its own resource group,
// VNet, and (when peerToHub) a peering in each direction.
//
//   name          short name; drives rg-<name>, vnet-<name>, rt-<name>
//   addressPrefix the VNet address space
//   role          'avd'  - session hosts and the storage private endpoint
//                          land here; its subnets get private endpoint
//                          network policies disabled
//                 'none' - ordinary spoke
//                 Exactly one spoke should have role 'avd'.
//   peerToHub     create hub<->spoke peerings
//   natGateway    create a NAT gateway + public IP in this spoke, giving it
//                 outbound internet. A NAT gateway cannot be shared across
//                 VNets, so each spoke needing one pays for its own
//                 (roughly £25-30/month plus data processing).
//                 Not needed when hubFirewallType routes traffic to a
//                 firewall that provides egress - and do not use both on
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
//   nsgType 'avd'   - documented AVD outbound allow rules. NOTE: these do
//                     not restrict outbound traffic; Azure's default
//                     AllowInternetOutBound still applies. They document
//                     required destinations, they do not enforce egress.
//           'empty' - no custom rules; an attachment point for customer
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
    name: 'snet-desktops'
    prefix: '10.3.0.0/24'
    nsgType: 'avd'
    useNatGateway: true
    hostsPrivateEndpoints: true
  }
  {
    spoke: 'prod'
    name: 'snet-servers'
    prefix: '10.1.0.0/24'
    nsgType: 'empty'
    useNatGateway: false
    hostsPrivateEndpoints: false
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
// NO internet access. The deployment still SUCCEEDS - the failure appears
// later as session hosts that never register. Check the
// spokesWithoutOutbound deployment output before you deploy.
//
// Set false only to keep Azure's legacy implicit outbound behaviour, which
// Microsoft is retiring.
param privateSubnets = true

// -----------------------------------------------------------------------------
// STORAGE
// -----------------------------------------------------------------------------

// false skips the storage account, share, private endpoint and DNS entirely.
param deployStorage = true

// Shared resource group for storage. Must NOT match any spoke name, since
// each spoke creates rg-<name>.
param storageRgName = 'rg-storage'

// MUST be globally unique across all of Azure. Lowercase letters and digits
// only, 3-24 characters. Change this before every deployment - the name
// below will already be taken.
param storageAccountName = 'stfslogixchangeme01'

// SKU and kind must be compatible:
//   Premium_LRS / Premium_ZRS  ->  kind FileStorage
//   Standard_*                 ->  kind StorageV2
// Premium is strongly recommended for FSLogix profile performance.
param storageSku = 'Premium_LRS'
param storageAccountKind = 'FileStorage'

// For FileStorage this is the only valid value.
param storageAccessTier = 'Hot'

param fileShareName = 'profiles'

// Premium file shares are provisioned - you pay for the quota, not usage.
param fileShareQuotaGiB = 512

// --- Storage security --------------------------------------------------------

param storageMinimumTlsVersion = 'TLS1_2'
param storageSupportsHttpsTrafficOnly = true
param storageAllowBlobPublicAccess = false
param storageAllowSharedKeyAccess = true

// Leave 'Enabled' for the first deployment so the control plane can create
// the share. After confirming the private endpoint resolves and a client can
// mount the share, redeploy with 'Disabled' to close the public path.
param storagePublicNetworkAccess = 'Enabled'

param storageLargeFileSharesState = 'Enabled'

param fslogixPrivateEndpointName = 'pe-fslogix-file'

// Microsoft Entra Kerberos. This is what lets FSLogix authenticate to the
// share with cloud-only identities. Setting it here makes the Storage resource
// provider create an application registration for the account; the Entra
// section below finishes the job.
param storageEnableEntraKerberos = true

// Share-level permission for every authenticated identity, beneath the
// per-group assignments below. 'None' means access is governed solely by those
// assignments, which is what you want. Anything else applies to every share in
// the account and cannot be scoped to one.
param storageDefaultSharePermission = 'None'

// Set NTFS permissions on the share root from the first session host, using
// Microsoft's documented profile container permission set. Azure RBAC decides
// who reaches the share; NTFS decides what they can do once they are on it,
// and the defaults let every user open every other user's profile.
param setFslogixNtfsPermissions = true

// -----------------------------------------------------------------------------
// ENTRA ID
// -----------------------------------------------------------------------------
// The Azure portal's deployment flow carries no Microsoft Graph token, so a
// template deployed from a Create blade cannot create groups or finish the
// Entra Kerberos setup by itself. A deployment script running as a
// user-assigned managed identity can.
//
// Create that identity once per tenant:
//   .\scripts\bootstrap-entra-identity.ps1 -Location northeurope
//
// Nothing needs copying afterwards. The identity is located by the name and
// resource group the script gives it, which are the defaults below. Change
// these only if the script was run with -IdentityName or -ResourceGroup.
//
// Set useEntraManagedIdentity to false to skip all Entra work and supply the
// group object IDs by hand instead.

// Hybrid only. Leave false on the first deployment: the Entra Kerberos setup
// is deferred until the domain controller exists in the hub and Entra Connect
// is syncing, because both halves need identities that are already synced.
// Build the domain controller, get sync running, then redeploy with this true.
param hybridDomainControllerReady = false

param useEntraManagedIdentity = true
param entraManagedIdentityName = 'id-avd-entra-ops'
param entraManagedIdentityRgName = 'rg-identity'

// Create the AVD access groups rather than supplying their object IDs.
// Requires the bootstrap managed identity. Groups are matched by display name, so
// redeploying reuses them instead of creating duplicates.
param createEntraGroups = false

param avdUsersGroupName = 'AVD Users'
param avdAdminsGroupName = 'AVD Admins'

// Grant admin consent and apply the kdc_enable_cloud_group_sids tag to the
// storage account's application. Both are mandatory for cloud-only Entra
// Kerberos - without the tag, Microsoft's wording is that authentication
// fails. Requires the bootstrap managed identity.
param configureEntraKerberos = true

// Used only when createEntraGroups is false.
//   users  -> SMB Share Contributor (read/write profiles), Desktop
//             Virtualization User on the app group, Virtual Machine User Login
//   admins -> SMB Share Elevated Contributor, Virtual Machine Administrator
//             Login
param avdUsersGroupObjectId = ''
param avdAdminsGroupObjectId = ''

// -----------------------------------------------------------------------------
// MONITORING
// -----------------------------------------------------------------------------

// false skips the workspace and all diagnostic settings.
param deployMonitoring = true

// Shared resource group for Log Analytics. Must NOT match any spoke name.
param monitoringRgName = 'rg-mgmt'

param logAnalyticsWorkspaceName = 'law-avd'

// Days, 30-730. Azure default is 30.
param logAnalyticsRetentionDays = 30

// PerGB2018 is the current pay-as-you-go SKU.
param logAnalyticsSku = 'PerGB2018'

// --- AVD Insights ------------------------------------------------------------
// Azure Monitor Agent on each session host plus a data collection rule
// carrying Microsoft's documented AVD counter and event set, including both
// FSLogix channels. This is the session host half of Insights; the control
// plane half is the diagnostic settings the template already applies.
param deployAvdInsights = true

// Per-process input delay instances scale with processes times sessions, so on
// a busy multi-session host this is a large share of ingestion cost for detail
// you rarely act on. Per-session is the signal users actually feel.
param collectPerProcessInputDelay = false

// --- Alerts ------------------------------------------------------------------
// An action group plus six rules: session host availability, connection
// failure rate, FSLogix errors, disk space, CPU and memory.
//
// Thresholds are judgement, not Microsoft guidance - they publish none for
// pooled multi-session. The windows are deliberately long enough to survive a
// logon storm.
param deployAlerts = true

// Blank still creates the action group and the rules, so alerts fire and are
// visible in the portal. Nobody is emailed until this is set.
param alertEmailAddress = ''

// Appears in alert emails. Azure caps it at 12 characters.
param alertActionGroupShortName = 'avdops'

param cpuAlertThresholdPercent = 85
param memoryAlertThresholdPercent = 10
param diskFreeAlertThresholdPercent = 10

// -----------------------------------------------------------------------------
// AVD CONTROL PLANE
// -----------------------------------------------------------------------------

// One entry per host pool. An empty array deploys no control plane at all.
//
// Every pool is Pooled with depth-first load balancing, and gets its own
// desktop application group. All application groups surface through the
// single workspace below.
//
//   name             becomes hp-<name> and ag-<name>-desktop
//   friendlyName     what users see in the AVD client
//   maxSessionLimit  concurrent sessions per session host. Depends on VM
//                    size - roughly 6-8 for 2 vCPU, 10-12 for 4 vCPU,
//                    16-20 for 8 vCPU.
//   startVMOnConnect power hosts on when a user connects. Requires the AVD
//                    service principal to hold Desktop Virtualization Power
//                    On Contributor on the subscription - a one-time manual
//                    step. Leave false until that is done.
//   sessionHostCount session hosts to build for this pool. Optional - omit
//                    or set 0 to create the pool with no hosts.
//   vmSize           session host size. Only used when sessionHostCount > 0.
//   desktopFriendlyName  what users see instead of "SessionDesktop" in their
//                    client. Optional; omit to leave it as SessionDesktop.
//                    Needs the bootstrap managed identity - AVD has no ARM property
//                    for this, so it is done with a REST call.
//   vmNamePrefix     optional. Defaults to the pool name, lowercased, with
//                    hyphens stripped, truncated to 11 characters. Set it
//                    explicitly if two pools would truncate to the same
//                    thing - duplicateSessionHostPrefixes flags that.
//
// The control plane lands in the AVD spoke's resource group, so one spoke
// must have role = 'avd'.

param hostPools = [
  {
    name: 'desktops'
    friendlyName: 'Desktops'
    maxSessionLimit: 10
    startVMOnConnect: false
    sessionHostCount: 2
    vmSize: 'Standard_D4as_v4'
    desktopFriendlyName: 'Finance Desktop'
  }
]

param avdWorkspaceName = 'ws-avd'
param avdWorkspaceFriendlyName = 'AVD Workspace'

// Registration token expiry defaults to 30 days from deployment time.
// Leave it alone unless you need a different window.
//
// The token is not a deployment output - deployment history persists, and a
// registration token is a credential. The session host module reads it
// directly from the host pool and puts it in the DSC extension's
// protectedSettings, so it never passes through an output at all. Fetch it
// manually only if you are adding hosts outside this template:
//   az desktopvirtualization hostpool retrieve-registration-token `
//     --resource-group rg-avd --host-pool-name hp-desktops

// -----------------------------------------------------------------------------
// SESSION HOSTS
// -----------------------------------------------------------------------------

// false builds the control plane with no VMs, whatever sessionHostCount says
// on each pool above. Useful when hosts come from a separate image pipeline.
param deploySessionHosts = true

// Break-glass local administrator on each host. Users sign in with their
// Entra credentials, not this account. Azure rejects 'administrator',
// 'admin', 'user', 'guest' and 'root'.
//
// Do NOT commit a real password. Supply it at deploy time instead:
//   az deployment sub create ... --parameters sessionHostAdminPassword='<value>'
param sessionHostAdminUsername = 'avdadmin'
param sessionHostAdminPassword = ''

// Windows 11 Enterprise multi-session 25H2 with Microsoft 365 Apps.
//
// The M365 images are published under the 'office-365' OFFER, not under
// 'windows-11'. For the equivalent without M365 Apps:
//   sessionHostImageOffer = 'windows-11'
//   sessionHostImageSku   = 'win11-25h2-avd'
param sessionHostImagePublisher = 'microsoftwindowsdesktop'
param sessionHostImageOffer = 'office-365'
param sessionHostImageSku = 'win11-25h2-avd-m365'
param sessionHostImageVersion = 'latest'

param sessionHostOsDiskType = 'StandardSSD_LRS'

// OS disk size in GB. 0 uses the image default of 128 GB. Disks grow but never
// shrink, so this can be raised later and not lowered. Profiles live on the
// FSLogix share, so it mostly matters for locally installed applications.
param sessionHostOsDiskSizeGB = 0

// Accelerated networking. Not supported by B-series sizes, and an
// unsupported size fails the deployment outright rather than degrading.
param sessionHostAcceleratedNetworking = true

// Windows time zone ID for the host clock, such as 'GMT Standard Time'.
// Empty leaves the Azure default of UTC.
param sessionHostTimeZone = ''

// Each session adopts the time zone of the client connecting to it, rather
// than the host's. A different mechanism from the line above, and they
// combine: the host keeps its own clock, sessions follow their client.
// Takes effect for new sessions, no restart needed.
param enableTimeZoneRedirection = false

// Enrol the hosts in Intune during the Entra join. Multi-session hosts
// enrol with device credentials and need AVD agent 1.0.2944.1400 or newer.
param sessionHostEnrolWithIntune = false

// The AVD DSC package that installs the agent and bootloader. Microsoft
// version-stamps this file and does not publish the current version in their
// documentation, so it is left at the template default unless you have a
// newer one. See the README.
// param sessionHostArtifactsLocation = '...'

// -----------------------------------------------------------------------------
// FSLOGIX ON THE SESSION HOSTS
// -----------------------------------------------------------------------------

// The gallery images ship FSLogix installed but NOT configured - the binaries
// are there and nothing points them at a share, which is why a freshly built
// host quietly keeps local profiles. This sets the profile container registry
// values and enables cloud Kerberos ticket retrieval, without which the host
// cannot authenticate to Azure Files at all.
//
// Skipped automatically when deployStorage is false.
param configureFslogixOnSessionHosts = true

// A ceiling, not an allocation. The container grows as the profile does.
param fslogixProfileSizeMB = 30000

// CloudKerberosTicketRetrievalEnabled is read by LSA at boot, so a host that is
// not restarted cannot authenticate to the share. Set false only if you are
// restarting the hosts yourself.
param restartSessionHostsAfterFslogix = true

// Apply desktopFriendlyName from the host pool rows above. Requires
// the bootstrap managed identity; the rename is a REST call from a deployment script,
// which the template grants Desktop Virtualization Application Group
// Contributor on the AVD resource group to make.
param setDesktopFriendlyNames = true
