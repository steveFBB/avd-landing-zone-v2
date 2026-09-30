// =============================================================================
// Action group and the starter alert set
// =============================================================================
// Four alerts, chosen because each one corresponds to a failure this project
// has actually hit or that users feel directly. Not thirty rules that get
// muted in a fortnight.
//
// THRESHOLDS ARE JUDGEMENT, NOT DOCUMENTATION
//
// Microsoft publishes no threshold guidance for pooled multi-session hosts.
// The defaults here are deliberately loose enough to survive a logon storm -
// a 5-minute window on CPU would page you every weekday at nine.
//
// skipQueryValidation IS ON, AND HAS TO BE
//
// The WVD* tables do not exist until the first diagnostic data lands. On a
// greenfield deployment they are minutes away at best, so validating the
// queries at deploy time fails the deployment on a brand new subscription.
// =============================================================================

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

param location string

@description('Log Analytics workspace the log alerts query.')
param logAnalyticsWorkspaceId string

@description('Resource group holding the session hosts, used as the scope for the metric alerts. They then cover hosts added later without a template change.')
param sessionHostResourceGroupId string

@description('Region the session hosts are in. Required by a multi-resource metric alert, and every scoped resource must be in this one region.')
param sessionHostRegion string

@description('Email address for alert notifications. Empty creates the action group with no receivers, so alerts still fire and are visible in the portal.')
param alertEmailAddress string = ''

@description('Short name shown in alert emails and texts. Azure caps this at 12 characters.')
@maxLength(12)
param actionGroupShortName string = 'avdops'

param actionGroupName string = 'ag-avd-alerts'

@description('Average CPU percentage over the window that counts as pressure.')
param cpuThresholdPercent int = 85

@description('Available memory percentage below which a host is considered under pressure.')
param memoryThresholdPercent int = 10

@description('Free space percentage on C: below which to alert. On a non-persistent host this usually means a profile is failing to redirect and is writing locally.')
param diskFreeThresholdPercent int = 10

@description('Deploy the log alerts. They need the WVD tables and the Event table, so turn them off if monitoring is minimal.')
param deployLogAlerts bool = true

@description('Deploy the metric alerts on session host CPU and memory.')
param deployMetricAlerts bool = true

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  tags: tags
  // Action groups are always global, whatever the resources they serve.
  location: 'global'
  properties: {
    groupShortName: actionGroupShortName
    enabled: true
    emailReceivers: empty(alertEmailAddress)
      ? []
      : [
          {
            name: 'primary'
            emailAddress: alertEmailAddress
            // Consistent payload shape across metric and log alerts, which
            // matters if these ever feed a webhook or a ticketing system.
            useCommonAlertSchema: true
          }
        ]
  }
}

// -----------------------------------------------------------------------------
// Session host availability
// -----------------------------------------------------------------------------
// WVDAgentHealthStatus is a change log, so a naive filter on Status fires on
// every historical blip. arg_max gives the current state per host.
//
// Hosts that are deliberately shut down are excluded - a scaling plan or a
// monthly rotation should not page anyone.
var sessionHostHealthQuery = '''
WVDAgentHealthStatus
| where TimeGenerated > ago(30m)
| summarize arg_max(TimeGenerated, Status, AllowNewSessions, _ResourceId) by SessionHostName
| where Status != "Available"
| project SessionHostName, Status, AllowNewSessions, _ResourceId
'''

resource sessionHostHealthAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (deployLogAlerts) {
  name: 'alert-avd-session-host-unhealthy'
  tags: tags
  // Must match the workspace's region or the deployment fails.
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: 'AVD session host unhealthy'
    description: 'A session host is not reporting Available. Users cannot connect to it.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: sessionHostHealthQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          resourceIdColumn: '_ResourceId'
          dimensions: [
            {
              name: 'SessionHostName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// Connection failures
// -----------------------------------------------------------------------------
// A failure rate rather than a count, so a quiet Sunday with two attempts and
// one failure does not read as a 50% outage. The attempt floor is what makes
// that work.
//
// A connection with a Started and no matching Connected for the same
// CorrelationId did not succeed.
var connectionFailureQuery = '''
let window = 1h;
let started = WVDConnections
    | where TimeGenerated > ago(window) and State == "Started"
    | distinct CorrelationId;
let connected = WVDConnections
    | where TimeGenerated > ago(window) and State == "Connected"
    | distinct CorrelationId;
let total = toscalar(started | count);
let failed = toscalar(started | join kind=leftanti connected on CorrelationId | count);
print FailureRatePct = iff(total == 0, 0.0, todouble(failed) * 100.0 / todouble(total)),
      TotalAttempts = total,
      FailedAttempts = failed
| where TotalAttempts > 20 and FailureRatePct > 10
'''

resource connectionFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (deployLogAlerts) {
  name: 'alert-avd-connection-failures'
  tags: tags
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: 'AVD connection failure rate'
    description: 'More than one in ten connection attempts is failing, over a meaningful number of attempts.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    // An hour, not less: Log Analytics ingestion lags by up to 15 minutes, so
    // a short window measures an incomplete picture.
    windowSize: 'PT1H'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: connectionFailureQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// FSLogix profile failures
// -----------------------------------------------------------------------------
// Built on channel and level rather than event IDs. Microsoft publishes no
// FSLogix event ID table - the IDs quoted around the internet are community
// folklore, and pinning an alert to unverified IDs means it silently stops
// matching when they change.
//
// Once you have a fortnight of real data, read off which EventIDs actually
// accompany genuine mount failures in your estate and narrow this query to
// them. make_set below is there to make that easy.
var fslogixFailureQuery = '''
Event
| where TimeGenerated > ago(30m)
| where EventLog startswith "Microsoft-FSLogix-Apps"
| where EventLevelName == "Error"
| summarize ErrorCount = count(),
            SampleMessage = any(RenderedDescription),
            EventIds = make_set(EventID, 10)
    by Computer, _ResourceId
| where ErrorCount > 0
'''

resource fslogixFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (deployLogAlerts) {
  name: 'alert-avd-fslogix-errors'
  tags: tags
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: 'FSLogix profile errors'
    description: 'A session host logged FSLogix errors. A failed profile mount gives the user a temporary profile and loses their session data.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT10M'
    windowSize: 'PT30M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: fslogixFailureQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          resourceIdColumn: '_ResourceId'
          dimensions: [
            {
              name: 'Computer'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// Disk free space
// -----------------------------------------------------------------------------
// A log alert rather than a metric alert, because there is no platform metric
// for free space - the OS disk metrics cover IOPS, throughput, latency and
// queue depth only. This depends on % Free Space being in the data collection
// rule, which is why avdInsightsDcr.bicep adds it to Microsoft's set.
var diskSpaceQuery = '''
Perf
| where TimeGenerated > ago(15m)
| where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
| where InstanceName == "C:"
| summarize FreePct = avg(CounterValue) by Computer, _ResourceId
| where FreePct < THRESHOLD
'''

resource diskSpaceAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (deployLogAlerts) {
  name: 'alert-avd-disk-space'
  tags: tags
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: 'Session host low disk space'
    description: 'A session host is low on C: space. On a non-persistent host this usually means a profile is failing to redirect and is writing locally.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: replace(diskSpaceQuery, 'THRESHOLD', string(diskFreeThresholdPercent))
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          resourceIdColumn: '_ResourceId'
          dimensions: [
            {
              name: 'Computer'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// CPU and memory
// -----------------------------------------------------------------------------
// Platform metrics, so no agent involved and nothing to collect. Scoped to the
// session host resource group rather than to named VMs, which means hosts
// added or rebuilt later are covered with no template change - exactly what a
// rotating pooled host pool needs.
resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (deployMetricAlerts) {
  name: 'alert-avd-session-host-cpu'
  tags: tags
  // Metric alerts are always global.
  location: 'global'
  properties: {
    description: 'Session host CPU is sustained above the threshold. A 15-minute window is deliberate - logon storms peg CPU for two or three minutes routinely.'
    severity: 2
    enabled: true
    scopes: [
      sessionHostResourceGroupId
    ]
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: sessionHostRegion
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'HighCpu'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          threshold: cpuThresholdPercent
          timeAggregation: 'Average'
        }
      ]
    }
    autoMitigate: true
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

resource memoryAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (deployMetricAlerts) {
  name: 'alert-avd-session-host-memory'
  tags: tags
  location: 'global'
  properties: {
    description: 'Session host available memory is below the threshold.'
    severity: 2
    enabled: true
    scopes: [
      sessionHostResourceGroupId
    ]
    targetResourceType: 'Microsoft.Compute/virtualMachines'
    targetResourceRegion: sessionHostRegion
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'LowMemory'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          metricName: 'Available Memory Percentage'
          operator: 'LessThan'
          threshold: memoryThresholdPercent
          timeAggregation: 'Average'
        }
      ]
    }
    autoMitigate: true
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

output actionGroupId string = actionGroup.id

@description('True when the action group has no email receiver, so alerts fire but nobody is told.')
output actionGroupHasNoReceiver bool = empty(alertEmailAddress)
