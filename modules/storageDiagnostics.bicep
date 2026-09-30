// Diagnostic settings for the storage account
//
// Two settings, because the useful data is at two levels:
//
//   account level - transaction metrics for the account as a whole. Logs
//                   at this level are not meaningful for FSLogix.
//   file service  - where FSLogix profile activity actually happens.
//                   StorageRead / StorageWrite / StorageDelete here are
//                   what you need when a profile fails to mount.
//
// Both settings can share a name because they are scoped to different
// resources.

param storageAccountName string
param workspaceId string
param diagnosticSettingName string = 'diag-to-law'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource accountDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: storageAccount
  name: diagnosticSettingName
  properties: {
    workspaceId: workspaceId
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource fileServiceDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: fileService
  name: diagnosticSettingName
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}
