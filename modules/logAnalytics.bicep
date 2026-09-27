// Log Analytics workspace
//
// One workspace, receiving infrastructure diagnostics from the VNets and
// the storage account.
//
// This is infrastructure logging only. AVD Insights needs diagnostics from
// the host pool, workspace and application groups plus agents on the
// session hosts, none of which this template configures.

@description('Tags applied to every resource in this module that supports them.')
param tags object = {}

param location string
param workspaceName string

@description('Data retention in days. Azure default is 30; valid range is 30-730.')
@minValue(30)
@maxValue(730)
param retentionInDays int

@description('''Create the Perf and Event tables explicitly rather than waiting for
Azure to materialise them. They are built-in, but not immediately present in a new
workspace, and anything referencing them before they appear fails.

Turn this off only if a tenant policy objects to writing built-in table resources; the
consequence is that a first deployment may fail on the data collection rule and the
disk space alert, and succeed on a redeploy.''')
param ensureBuiltInTables bool = true

@allowed([
  'PerGB2018'
  'CapacityReservation'
  'Free'
  'Standalone'
  'PerNode'
  'Standard'
  'Premium'
])
@description('PerGB2018 is the current pay-as-you-go SKU. The others exist for legacy workspaces.')
param sku string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  tags: tags
  location: location
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    features: {
      // Permissions on each resource control who can read its logs, rather
      // than requiring separate workspace-level RBAC.
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// -----------------------------------------------------------------------------
// Built-in tables
// -----------------------------------------------------------------------------
// Perf and Event are built-in, but they are NOT present the instant a workspace
// is created — they materialise a little later. A data collection rule that
// names them as an output stream is rejected with InvalidOutputTable until they
// exist, and a log alert querying Perf fails with a permissions-flavoured error
// that says nothing useful.
//
// In a template that creates the workspace and then immediately creates both,
// that is a race: it fails on a fresh deployment and succeeds on a redeploy
// minutes later, which is exactly what we saw.
//
// Declaring them here forces them into existence and, more importantly, gives
// the DCR and the alerts something concrete to depend on. Setting retention is
// the only meaningful property on a built-in table; the schema is fixed.
resource perfTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = if (ensureBuiltInTables) {
  parent: workspace
  name: 'Perf'
  properties: {
    retentionInDays: retentionInDays
  }
}

resource eventTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = if (ensureBuiltInTables) {
  parent: workspace
  name: 'Event'
  properties: {
    retentionInDays: retentionInDays
  }
  dependsOn: [
    // Table writes on one workspace are serialised; parallel ones conflict.
    perfTable
  ]
}

output workspaceId string = workspace.id
output workspaceName string = workspace.name

@description('''Names of the built-in tables this module ensured exist. Anything that
consumes Perf or Event — the AVD Insights data collection rule, the log alerts — should
depend on this rather than on the workspace alone.''')
output builtInTables array = ensureBuiltInTables ? [perfTable!.name, eventTable!.name] : []
