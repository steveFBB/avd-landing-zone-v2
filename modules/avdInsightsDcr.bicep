// =============================================================================
// Data collection rule for Azure Virtual Desktop Insights
// =============================================================================
// AVD Insights needs two halves, and only one of them is this file:
//
//   1. Control plane diagnostics on the host pool, application groups and
//      workspace. Those produce the WVD* tables and are already wired up by
//      avdHostPool.bicep and friends.
//   2. Session host telemetry — performance counters and event logs — which is
//      what this rule collects, delivered by the Azure Monitor Agent on each
//      host.
//
// There is no workbook to deploy. Insights is a built-in portal experience
// that discovers whatever data is present; the template's job is to produce
// the inputs.
//
// THE COUNTER NAMES ARE NOT WHAT THE DOCUMENTATION PRINTS
//
// Microsoft's AVD Insights glossary lists counters by display name. Two of
// them are not valid counter specifiers:
//
//   "Logical Disk(C:)"  ->  \LogicalDisk(C:)    no space in the object name
//   "Memory(*)"         ->  \Memory             the Memory object has no
//                                               instances, so (*) matches
//                                               nothing
//
// Copied verbatim from the documentation, those two collect nothing at all and
// say nothing about it. The specifiers below are corrected.
//
// Two sampling rates means two data sources: samplingFrequencyInSeconds is a
// property of the data source, not of the individual counter.
// =============================================================================

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

param location string

param dcrName string = 'dcr-avd-insights'

@description('Log Analytics workspace the collected data goes to.')
param logAnalyticsWorkspaceId string

@description('''Names of the built-in tables the caller has ensured exist. Not used in
the rule — it is here so that passing it creates a real dependency on those tables, which
must exist before a DCR naming Perf or Event as an output stream will be accepted.''')
param requiredTables array = []

@description('''Collect per-process input delay as well as per-session.

Per-process instances scale with processes multiplied by sessions, so on a busy
multi-session host this is a large share of ingestion cost for detail you rarely act
on. Per-session is the signal that matches what users feel.''')
param collectPerProcessInputDelay bool = false

// Not part of Microsoft's AVD Insights set, added because the disk space alert
// needs it and there is no platform metric for free space.
var freeSpaceCounter = '\\LogicalDisk(C:)\\% Free Space'

var thirtySecondCounters = union(
  [
    '\\LogicalDisk(C:)\\Avg. Disk Queue Length'
    '\\LogicalDisk(C:)\\Current Disk Queue Length'
    '\\Memory\\Available Mbytes'
    '\\Memory\\Page Faults/sec'
    '\\Memory\\Pages/sec'
    '\\Memory\\% Committed Bytes In Use'
    '\\PhysicalDisk(*)\\Avg. Disk Queue Length'
    '\\PhysicalDisk(*)\\Avg. Disk sec/Read'
    '\\PhysicalDisk(*)\\Avg. Disk sec/Transfer'
    '\\PhysicalDisk(*)\\Avg. Disk sec/Write'
    '\\Processor Information(_Total)\\% Processor Time'
    '\\User Input Delay per Session(*)\\Max Input Delay'
    '\\RemoteFX Network(*)\\Current TCP RTT'
    '\\RemoteFX Network(*)\\Current UDP Bandwidth'
  ],
  collectPerProcessInputDelay ? ['\\User Input Delay per Process(*)\\Max Input Delay'] : []
)

// Level numbering, per the Windows event schema:
//   0 LogAlways  1 Critical  2 Error  3 Warning  4 Information  5 Verbose
//
// Level 0 is included alongside 4 deliberately. Plenty of providers write
// informational events as LogAlways rather than Information, and FSLogix is
// one of them — filtering on Level=4 alone loses much of what Microsoft's
// documented set asks for.
var errorAndWarning = '*[System[(Level=2 or Level=3)]]'
var errorWarningAndInfo = '*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  tags: tags
  location: location
  kind: 'Windows'
  properties: {
    description: 'Performance counters and event logs for Azure Virtual Desktop Insights. Tables ensured: ${join(requiredTables, ', ')}'
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounters30s'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 30
          counterSpecifiers: thirtySecondCounters
        }
        {
          name: 'perfCounters60s'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\LogicalDisk(C:)\\Avg. Disk sec/Transfer'
            // The disk space alert runs on a 15-minute window, so sampling
            // free space every 30 seconds buys nothing but ingestion cost.
            freeSpaceCounter
            '\\Terminal Services(*)\\Active Sessions'
            '\\Terminal Services(*)\\Inactive Sessions'
            '\\Terminal Services(*)\\Total Sessions'
          ]
        }
      ]
      windowsEventLogs: [
        {
          name: 'avdEventLogs'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'Application!${errorAndWarning}'
            'System!${errorAndWarning}'
            'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin!${errorWarningAndInfo}'
            'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational!${errorWarningAndInfo}'
            'Microsoft-FSLogix-Apps/Operational!${errorWarningAndInfo}'
            'Microsoft-FSLogix-Apps/Admin!${errorWarningAndInfo}'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'avdWorkspace'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    // Microsoft-Perf lands in the Perf table and Microsoft-Event in Event.
    // Microsoft-WindowsEvent would go to the WindowsEvent table instead, where
    // the Insights workbook does not look for it.
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'avdWorkspace'
        ]
      }
      {
        streams: [
          'Microsoft-Event'
        ]
        destinations: [
          'avdWorkspace'
        ]
      }
    ]
  }
}

output dcrId string = dcr.id
output dcrName string = dcr.name
