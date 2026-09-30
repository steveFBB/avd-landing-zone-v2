// =============================================================================
// Azure Firewall with an AVD egress policy
// =============================================================================
// The alternative to the FortiGate path, and the only one this template can
// deploy end to end - a FortiGate needs marketplace terms accepted per
// subscription, a plan block and licensing decisions a template cannot make.
//
// It is also the better of the two for route tables. With FortiGate you have
// to tell the template the appliance's internal IP by hand; here the private
// IP is an output of the firewall, so the spoke routes are derived rather than
// transcribed.
//
// ORDERING MATTERS, AND GETS THIS WRONG SILENTLY
//
// Session hosts Entra join on first boot. If a spoke's default route is
// pointing at the firewall before the firewall has rules, that join fails and
// the host registers as unusable - the failure we have already seen once in
// this project. The firewall therefore depends on its rule collection group,
// and main.bicep makes the route tables depend on the firewall.
//
// BASIC TIER IS NOT JUST A CHEAPER STANDARD
//
//   - It requires a management NIC, unconditionally, in its own
//     AzureFirewallManagementSubnet with its own public IP.
//   - It cannot do FQDN filtering in network rules, so the KMS rule below uses
//     a service tag rather than a hostname.
//   - 250 Mbps throughput, which is a real ceiling for a pooled AVD estate.
//
// The policy tier must match the firewall tier, or deployment fails.
// =============================================================================

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

param location string

param firewallName string
param policyName string

@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param tier string = 'Standard'

@description('Resource ID of the hub VNet. AzureFirewallSubnet is resolved from it.')
param hubVnetId string

@description('Address ranges allowed to egress through the firewall - normally the spoke VNet prefixes.')
param allowedSourceAddresses array

@description('Log Analytics workspace resource ID for firewall diagnostics. Empty skips them.')
param logAnalyticsWorkspaceId string = ''

@description('Availability zones for the firewall. Empty deploys it regional. Spreading across zones costs nothing beyond inter-zone data.')
param availabilityZones array = []

@description('''Allow the Microsoft Intune enrolment endpoints.

None of them are covered by the AzureActiveDirectory or WindowsVirtualDesktop tags, so
without this the Entra join succeeds and MDM enrolment silently does not happen. Set
true whenever session hosts enrol in Intune.''')
param allowIntuneEnrolment bool = false

var needsManagementNic = tier == 'Basic'

// Endpoint hostnames are derived from the cloud rather than written in, so
// these rules are correct in sovereign clouds and not just commercial Azure.
// environment() returns full URLs, so the scheme and trailing slash come off.
var loginHost = replace(replace(environment().authentication.loginEndpoint, 'https://', ''), '/', '')
var armHost = replace(replace(environment().resourceManager, 'https://', ''), '/', '')
var storageSuffix = environment().suffixes.storage

// Standard SKU, static allocation. Basic-SKU public IPs were never supported
// for Azure Firewall and are retired.
resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: 'pip-${firewallName}'
  tags: tags
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: empty(availabilityZones) ? null : availabilityZones
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource managementPublicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = if (needsManagementNic) {
  name: 'pip-${firewallName}-mgmt'
  tags: tags
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: empty(availabilityZones) ? null : availabilityZones
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: policyName
  tags: tags
  location: location
  properties: {
    sku: {
      // Must match the firewall tier exactly.
      tier: tier
    }
    threatIntelMode: 'Alert'
  }
}

// Rule collection groups on one policy cannot be written concurrently, so
// everything AVD needs lives in a single group. Splitting it later means
// chaining the groups with dependsOn.
//
// Processing order is fixed by Azure: DNAT, then network, then application -
// priority does not change that. A network rule that matches ends evaluation,
// so the network collection is deliberately narrow and the broad FQDN matching
// happens in the application collection where it is logged by hostname.
resource rules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: 'avd-egress'
  properties: {
    priority: 200
    ruleCollections: [
      {
        name: 'avd-network'
        priority: 200
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            // Service tags rather than FQDNs: works on every tier, needs no
            // DNS proxy, and tracks Microsoft's IP ranges automatically.
            name: 'avd-control-plane-and-platform'
            ruleType: 'NetworkRule'
            ipProtocols: [
              'TCP'
            ]
            sourceAddresses: allowedSourceAddresses
            destinationAddresses: [
              'WindowsVirtualDesktop'
              'AzureActiveDirectory'
              'AzureMonitor'
              'AzureResourceManager'
              'AzureFrontDoor.Frontend'
              'AzureFrontDoor.FirstParty'
              'Storage'
            ]
            destinationPorts: [
              '443'
            ]
          }
          {
            // Relayed RDP over STUN/TURN. Without this, connections fall back
            // to TCP and shortpath never works.
            name: 'rdp-shortpath-stun'
            ruleType: 'NetworkRule'
            ipProtocols: [
              'UDP'
            ]
            sourceAddresses: allowedSourceAddresses
            destinationAddresses: [
              'WindowsVirtualDesktop'
            ]
            destinationPorts: [
              '3478'
            ]
          }
          {
            // SMB to Azure Files. Only used when the share has NO private
            // endpoint: with one, the spoke's own system route is longer than
            // the firewall's 10.0.0.0/8 route and the traffic never comes here.
            // Without this rule that configuration fails at the last step, with
            // FSLogix quietly falling back to local profiles.
            name: 'azure-files-smb'
            ruleType: 'NetworkRule'
            ipProtocols: [
              'TCP'
            ]
            sourceAddresses: allowedSourceAddresses
            destinationAddresses: [
              'Storage'
            ]
            destinationPorts: [
              '445'
            ]
          }
          {
            // Windows activation. Deliberately a service tag and not
            // azkms.core.windows.net: FQDN filtering in a network rule needs
            // DNS proxy and is unavailable on the Basic tier, and port 1688
            // cannot go in an application rule because those are HTTP/HTTPS
            // only. Port 1688 is KMS and nothing else, so the breadth is
            // tolerable.
            name: 'windows-activation-kms'
            ruleType: 'NetworkRule'
            ipProtocols: [
              'TCP'
            ]
            sourceAddresses: allowedSourceAddresses
            destinationAddresses: [
              'AzureCloud'
            ]
            destinationPorts: [
              '1688'
            ]
          }
        ]
      }
      {
        name: 'avd-application'
        priority: 300
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: concat([
          {
            // Microsoft maintains the FQDN list behind this tag against their
            // own required-URL documentation, which is worth more than a list
            // copied into a template and left to rot.
            name: 'avd-fqdn-tag'
            ruleType: 'ApplicationRule'
            sourceAddresses: allowedSourceAddresses
            fqdnTags: [
              'WindowsVirtualDesktop'
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
          }
          {
            // Entra join and Azure RBAC sign-in. Neither of these is in the
            // AVD required-URL list, and pas.windows.net in particular is not
            // reliably covered by the AzureActiveDirectory service tag -
            // without it the device joins and then nobody can sign in.
            name: 'entra-join-and-signin'
            ruleType: 'ApplicationRule'
            sourceAddresses: allowedSourceAddresses
            targetFqdns: [
              'enterpriseregistration.windows.net'
              loginHost
              'device.${loginHost}'
              'pas.windows.net'
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
          }
          {
            // Certificate and CTL endpoints, six of which are HTTP on port 80
            // rather than HTTPS. An HTTPS-only rule set breaks attestation
            // certificate provisioning, and the symptom is nothing obvious.
            name: 'certificates-http'
            ruleType: 'ApplicationRule'
            sourceAddresses: allowedSourceAddresses
            targetFqdns: [
              'oneocsp.microsoft.com'
              'www.microsoft.com'
              'ctldl.windowsupdate.com'
              '*.aikcertaia.microsoft.com'
              '*.microsoftaik.azure.net'
              'azcsprodeusaikpublish.blob.${storageSuffix}'
            ]
            protocols: [
              {
                protocolType: 'Http'
                port: 80
              }
            ]
          }
          {
            // Azure Monitor Agent control endpoints, needed for AVD Insights.
            name: 'azure-monitor-agent'
            ruleType: 'ApplicationRule'
            sourceAddresses: allowedSourceAddresses
            targetFqdns: [
              'global.handler.control.monitor.azure.com'
              '*.handler.control.monitor.azure.com'
              '*.ods.opinsights.azure.com'
              armHost
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
          }
        ], allowIntuneEnrolment ? [
          {
            name: 'intune-enrolment'
            ruleType: 'ApplicationRule'
            sourceAddresses: allowedSourceAddresses
            targetFqdns: [
              'manage.microsoft.com'
              '*.manage.microsoft.com'
              'enrollment.manage.microsoft.com'
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
          }
        ] : [])
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: firewallName
  tags: tags
  location: location
  zones: empty(availabilityZones) ? null : availabilityZones
  // The rules must exist before traffic is forced through the firewall.
  dependsOn: [
    rules
  ]
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: tier
    }
    firewallPolicy: {
      id: policy.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${hubVnetId}/subnets/AzureFirewallSubnet'
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    managementIpConfiguration: needsManagementNic
      ? {
          name: 'mgmtconfig'
          properties: {
            subnet: {
              id: '${hubVnetId}/subnets/AzureFirewallManagementSubnet'
            }
            publicIPAddress: {
              id: managementPublicIp!.id
            }
          }
        }
      : null
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  scope: firewall
  name: 'diag-to-law'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

@description('''Private IP of the firewall, for the spoke route tables. Read from the
resource rather than supplied, so it cannot be transcribed wrongly.

Note: stopping and starting a firewall can change this. If you deallocate one to save
money, redeploy afterwards so the routes are refreshed.''')
output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress

output firewallId string = firewall.id
output publicIp string = publicIp.properties.ipAddress
