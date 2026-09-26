// FSLogix storage account and profile share
//
// One account, shared across every host pool. A storage account supports
// only one identity source for Azure Files, so every host pool in a
// deployment shares the same identity model — which for this template is
// cloud-only Microsoft Entra Kerberos.
//
// Setting directoryServiceOptions to AADKERB here makes the Storage resource
// provider create an application registration for the account. That
// application still needs admin consent and the kdc_enable_cloud_group_sids
// tag before anyone can mount the share — storageEntraKerberos.bicep does
// both. NTFS permissions on the share root are set separately again, from a
// session host, because they need a mounted client.
//
// Security settings are all parameterised rather than defaulted, so the
// values are visible in the customer's parameters file instead of hidden
// in the template.

param location string
param storageAccountName string

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
@description('SKU and kind must be compatible: Premium_* requires kind FileStorage, Standard_* requires StorageV2.')
param storageSku string

@allowed([
  'StorageV2'
  'FileStorage'
])
param storageAccountKind string

@allowed([
  'Hot'
  'Cool'
])
param storageAccessTier string

param fileShareName string

@description('Share quota in GiB. Premium file shares are provisioned — you pay for the quota, not consumption.')
@minValue(100)
@maxValue(102400)
param fileShareQuotaGiB int

@allowed([
  'TLS1_0'
  'TLS1_1'
  'TLS1_2'
  'TLS1_3'
])
param minimumTlsVersion string

param supportsHttpsTrafficOnly bool
param allowBlobPublicAccess bool
param allowSharedKeyAccess bool

@allowed([
  'Enabled'
  'Disabled'
])
@description('Leave Enabled for the initial deployment so the control plane can create the share, then flip to Disabled once the private endpoint is validated.')
param publicNetworkAccess string

@allowed([
  'Enabled'
  'Disabled'
])
param largeFileSharesState string

@description('''Enable Microsoft Entra Kerberos for Azure Files. A storage account
supports exactly one identity source, so this is an account-wide decision that every
host pool in the deployment inherits. Off leaves the account with no SMB identity
source at all, which means FSLogix cannot authenticate to the share.''')
param enableEntraKerberos bool = true

@description('''Share-level permission granted to every authenticated identity, as a
floor beneath the per-group role assignments. \'None\' is the safe default: access is
then governed solely by the explicit role assignments in storageRbac.bicep. Setting
anything else applies to every share in the account and cannot be scoped.''')
@allowed([
  'None'
  'StorageFileDataSmbShareReader'
  'StorageFileDataSmbShareContributor'
  'StorageFileDataSmbShareElevatedContributor'
])
param defaultSharePermission string = 'None'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: storageSku
  }
  kind: storageAccountKind
  properties: {
    accessTier: storageAccessTier
    minimumTlsVersion: minimumTlsVersion
    supportsHttpsTrafficOnly: supportsHttpsTrafficOnly
    allowBlobPublicAccess: allowBlobPublicAccess
    allowSharedKeyAccess: allowSharedKeyAccess
    publicNetworkAccess: publicNetworkAccess
    largeFileSharesState: largeFileSharesState
    azureFilesIdentityBasedAuthentication: enableEntraKerberos
      ? {
          directoryServiceOptions: 'AADKERB'
          defaultSharePermission: defaultSharePermission
        }
      : {
          directoryServiceOptions: 'None'
        }
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileServices
  name: fileShareName
  properties: {
    shareQuota: fileShareQuotaGiB
    enabledProtocols: 'SMB'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output fileShareName string = fileShare.name
