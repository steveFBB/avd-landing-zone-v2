// =============================================================================
// NTFS permissions on the FSLogix share root
// =============================================================================
// Azure RBAC decides who can reach the share. NTFS decides what they can do
// once they are on it. Both are required, and the second one cannot be done
// from ARM directly because it needs a mounted SMB client — so it runs as a
// Run Command on the first session host.
//
// The share is mounted with the storage account key rather than a user
// identity. That is deliberate: the account key is the only credential that
// bypasses NTFS entirely, which is exactly what you need to set the initial
// permissions on a share nobody has access to yet. It also means this step
// does not depend on Entra Kerberos being finished.
//
// The permission set is Microsoft's documented one for profile containers:
//
//   AVD users      Modify, this folder only
//                  — enough to create their own profile folder, not enough to
//                    open anyone else's
//   CREATOR OWNER  Modify, subfolders and files only
//                  — each user owns the folder they created
//   Administrators Modify, everything
//
// Cloud-only Entra groups have no on-premises SID, so the group's object ID is
// converted to its Entra SID form (S-1-12-1-...) and passed to icacls as a
// literal SID. Referring to the group by name would need name resolution the
// host may not have at this point in its life.
// =============================================================================

param location string

@description('Session host to run this on. Any host with a route to the share will do; the caller uses the first.')
param vmName string

param storageAccountName string

@description('Resource group holding the storage account. The key is read here rather than passed in, so it never crosses a module boundary.')
param storageRgName string

param fileShareName string

@description('Entra object ID of the AVD users group. Converted to an Entra SID on the host.')
param avdUsersGroupObjectId string

@description('''Fail the deployment if the permissions cannot be set. True by default:
a share with default NTFS permissions looks fine and then leaks every user's profile
to every other user, which is not something to discover quietly.''')
param failDeploymentOnError bool = true

param fileEndpointSuffix string = environment().suffixes.storage

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

// listKeys() is treated as a secret by Bicep, so the key does not leak into
// deployment history the way a plain reference() would.
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
  scope: resourceGroup(storageRgName)
}

resource setPermissions 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'Set-FslogixNtfsPermissions'
  location: location
  properties: {
    asyncExecution: false
    timeoutInSeconds: 900
    treatFailureAsDeploymentFailure: failDeploymentOnError
    parameters: [
      {
        name: 'StorageAccountName'
        value: storageAccountName
      }
      {
        name: 'ShareName'
        value: fileShareName
      }
      {
        name: 'EndpointSuffix'
        value: fileEndpointSuffix
      }
      {
        name: 'UsersGroupObjectId'
        value: avdUsersGroupObjectId
      }
    ]
    protectedParameters: [
      {
        name: 'StorageAccountKey'
        value: storageAccount.listKeys().keys[0].value
      }
    ]
    source: {
      script: '''
        param(
          [string]$StorageAccountName,
          [string]$ShareName,
          [string]$EndpointSuffix,
          [string]$UsersGroupObjectId,
          [string]$StorageAccountKey
        )

        $ErrorActionPreference = 'Stop'

        # A cloud-only Entra group's SID is derived from its object ID: the GUID
        # is read as four little-endian 32-bit integers appended to S-1-12-1.
        function ConvertTo-EntraSid {
          param([string]$ObjectId)
          $bytes = ([Guid]$ObjectId).ToByteArray()
          $parts = 0..3 | ForEach-Object { [System.BitConverter]::ToUInt32($bytes, $_ * 4) }
          return "S-1-12-1-$($parts -join '-')"
        }

        $uncPath = "\\$StorageAccountName.file.$EndpointSuffix\$ShareName"
        Write-Output "Share: $uncPath"

        # Mount with the account key. Azure Files wants the account name in the
        # Azure\ domain for key-based auth.
        #
        # No 2>&1 here: redirecting a native command's stderr turns its output
        # into error records, and with ErrorActionPreference Stop that throws a
        # raw handler error before the useful message below ever runs.
        net use $uncPath /user:"Azure\$StorageAccountName" $StorageAccountKey | Out-Null
        if ($LASTEXITCODE -ne 0) {
          throw "Could not mount $uncPath. Check that the private endpoint resolves from this host and that shared key access is enabled on the storage account."
        }

        try {
          $usersSid = ConvertTo-EntraSid -ObjectId $UsersGroupObjectId
          Write-Output "AVD users group SID: $usersSid"

          # Set-Acl rather than icacls, and this is not a style preference.
          # icacls resolves every SID to an account name before it will write
          # an ACE, and an Entra-joined host cannot resolve a cloud-only group
          # it has never seen — it fails with 1332, "No mapping between account
          # names and security IDs was done". Set-Acl takes a SecurityIdentifier
          # object and writes the raw SID, which is what we actually want.
          $acl = Get-Acl -Path $uncPath

          $administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
          $creatorOwner   = New-Object System.Security.Principal.SecurityIdentifier('S-1-3-0')
          $avdUsers       = New-Object System.Security.Principal.SecurityIdentifier($usersSid)
          $authUsers      = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-11')
          $builtinUsers   = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')

          # The default ACL on a new Azure file share root is EXPLICIT, not
          # inherited — a share root has no parent directory — so removing
          # inheritance achieves nothing. The entry that matters is
          # Authenticated Users with Modify and full inheritance: leave it and
          # every user keeps Modify on every other user's profile.
          #
          # Purging our own three principals as well makes re-running this
          # idempotent instead of stacking duplicate ACEs.
          foreach ($principal in @($authUsers, $builtinUsers, $administrators, $creatorOwner, $avdUsers)) {
            $acl.PurgeAccessRules($principal)
          }

          $containerAndObject = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
          $noInherit         = [System.Security.AccessControl.InheritanceFlags]::None
          $propagateNormally = [System.Security.AccessControl.PropagationFlags]::None
          $childrenOnly      = [System.Security.AccessControl.PropagationFlags]::InheritOnly
          $allow             = [System.Security.AccessControl.AccessControlType]::Allow
          $modify            = [System.Security.AccessControl.FileSystemRights]::Modify
          $fullControl       = [System.Security.AccessControl.FileSystemRights]::FullControl

          # Administrators: full control everywhere. Full rather than Modify so
          # an admin can repair a broken profile ACL without remounting with the
          # account key.
          $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $administrators, $fullControl, $containerAndObject, $propagateNormally, $allow)))

          # CREATOR OWNER: modify, subfolders and files only. This is what makes
          # each user the owner of the profile folder they create.
          $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $creatorOwner, $modify, $containerAndObject, $childrenOnly, $allow)))

          # AVD users: modify, THIS FOLDER ONLY — no inheritance. They can
          # create their own folder and cannot open anyone else's.
          $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $avdUsers, $modify, $noInherit, $propagateNormally, $allow)))

          Set-Acl -Path $uncPath -AclObject $acl

          Write-Output "--- Resulting ACL ---"
          # Asked for as SIDs, because translating a cloud-only group SID to a
          # name is exactly what fails on this host.
          $final = Get-Acl -Path $uncPath
          foreach ($rule in $final.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            Write-Output ("{0}  {1}  inherit={2}  propagate={3}" -f `
              $rule.IdentityReference.Value, $rule.FileSystemRights, $rule.InheritanceFlags, $rule.PropagationFlags)
          }
        }
        finally {
          net use $uncPath /delete /y | Out-Null
        }

        Write-Output "FSLogix NTFS permissions applied."
      '''
    }
  }
}
