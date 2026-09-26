// =============================================================================
// Session hosts for one host pool
// =============================================================================
// Builds sessionHostCount VMs, joins each to Microsoft Entra ID, then
// registers it with the host pool.
//
// ORDER MATTERS. The Entra join must complete before the AVD agent installs,
// or the agent registers the host as domain-joined and sign-in fails with no
// obvious cause. That is what the dependsOn between the two extensions is
// for — it is not decoration.
//
// The registration token is read here rather than passed in, so it never
// appears in a module output or in deployment history. listRegistrationTokens()
// is a list* function, which Bicep treats as a secret for exactly that reason.
// The older hostPool.properties.registrationInfo.token accessor returns null
// on API versions from 2023-09-05 onward, so do not go back to it.
// =============================================================================

param location string

@description('Existing host pool to register these hosts with.')
param hostPoolName string

@minValue(1)
@maxValue(50)
param sessionHostCount int

param vmSize string

@description('Computer name prefix. VMs are named <prefix>-<index>. Windows caps computer names at 15 characters, so the caller truncates this to 11.')
@maxLength(11)
param vmNamePrefix string

param subnetId string

@secure()
param adminUsername string

@secure()
param adminPassword string

param imagePublisher string
param imageOffer string
param imageSku string
param imageVersion string

param osDiskType string

@description('URL of the AVD DSC configuration package. Microsoft version-stamps this and does not publish the current version — see the README.')
param artifactsLocation string

@description('Enrol in Intune as part of the Entra join. Requires Entra ID P1.')
param enrolWithIntune bool = false

@description('Accelerated networking. Unsupported on B-series sizes, and the deployment fails rather than degrading.')
param acceleratedNetworking bool = true

@description('Index of the first VM. Raise this when adding hosts to a pool that already has some, or the names collide.')
param startIndex int = 0

@description('''Configure FSLogix profile containers and cloud Kerberos on each host.

The gallery images ship FSLogix installed but NOT configured — the binaries are
there and nothing points them at a share, which is why a freshly built host has
no profile container. Off leaves that to an image pipeline or Intune.''')
param configureFslogix bool = false

@description('Storage account holding the profile share. Required when configureFslogix is true.')
param fslogixStorageAccountName string = ''

@description('File share for profile containers. Required when configureFslogix is true.')
param fslogixShareName string = ''

@description('Maximum profile container size in MB. FSLogix grows the VHDX up to this; it is a ceiling, not an allocation.')
param fslogixProfileSizeMB int = 30000

@description('Storage endpoint suffix, derived so this still works in sovereign clouds.')
param fileEndpointSuffix string = environment().suffixes.storage

@description('''Restart each host after configuring FSLogix. Needed, not cosmetic:
CloudKerberosTicketRetrievalEnabled is read by LSA at boot, so until the host
restarts it will not request a cloud Kerberos ticket and cannot authenticate to
the share. The restart is scheduled two minutes out so the Run Command returns
cleanly first.''')
param restartAfterFslogixConfiguration bool = true

// Microsoft Intune's first-party application ID. Passing it as mdmId during
// the Entra join is what triggers automatic MDM enrolment.
var intuneMdmId = '0000000a-0000-0000-c000-000000000000'

// The settings block has to be ABSENT when not enrolling in Intune, not empty
// and not null. Given an empty object the extension goes looking for mdmId and
// fails the VM with "'mdmId' setting was not found". So the properties are
// built by union() rather than with a conditional settings property, which
// guarantees the key simply is not there.
var entraJoinProperties = {
  publisher: 'Microsoft.Azure.ActiveDirectory'
  type: 'AADLoginForWindows'
  typeHandlerVersion: '1.0'
  autoUpgradeMinorVersion: true
}

var entraJoinIntuneProperties = {
  settings: {
    mdmId: intuneMdmId
  }
}

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' existing = {
  name: hostPoolName
}

resource nics 'Microsoft.Network/networkInterfaces@2024-01-01' = [
  for i in range(startIndex, sessionHostCount): {
    name: 'nic-${vmNamePrefix}-${i}'
    location: location
    properties: {
      enableAcceleratedNetworking: acceleratedNetworking
      ipConfigurations: [
        {
          name: 'ipconfig1'
          properties: {
            privateIPAllocationMethod: 'Dynamic'
            subnet: {
              id: subnetId
            }
          }
        }
      ]
    }
  }
]

resource vms 'Microsoft.Compute/virtualMachines@2024-07-01' = [
  for i in range(startIndex, sessionHostCount): {
    name: '${vmNamePrefix}-${i}'
    location: location
    // AADLoginForWindows gets its device-join token from IMDS using the VM's
    // own identity, so this has to be here before the extension installs.
    // Without it the extension fails, the host never actually joins Entra ID,
    // and the AVD agent then registers a host nobody can sign in to.
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      hardwareProfile: {
        vmSize: vmSize
      }
      // Windows 11 multi-session and Server 2025 are Generation 2 images, so
      // Trusted Launch is available and there is no reason not to use it.
      securityProfile: {
        securityType: 'TrustedLaunch'
        uefiSettings: {
          secureBootEnabled: true
          vTpmEnabled: true
        }
      }
      storageProfile: {
        imageReference: {
          publisher: imagePublisher
          offer: imageOffer
          sku: imageSku
          version: imageVersion
        }
        osDisk: {
          name: 'osdisk-${vmNamePrefix}-${i}'
          createOption: 'FromImage'
          caching: 'ReadWrite'
          deleteOption: 'Delete'
          managedDisk: {
            storageAccountType: osDiskType
          }
        }
      }
      osProfile: {
        computerName: '${vmNamePrefix}-${i}'
        adminUsername: adminUsername
        adminPassword: adminPassword
        windowsConfiguration: {
          // Session hosts are rebuilt, not patched in place. Automatic updates
          // on a pooled host fights the image pipeline and reboots users out.
          enableAutomaticUpdates: false
          provisionVMAgent: true
          patchSettings: {
            patchMode: 'Manual'
          }
        }
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: nics[i - startIndex].id
            properties: {
              deleteOption: 'Delete'
            }
          }
        ]
      }
      // The Windows Client benefit for multi-session images. Without it the
      // VM is billed as if it carried its own Windows licence.
      licenseType: 'Windows_Client'
    }
  }
]

// Entra join. This must finish before the AVD agent goes on.
resource entraJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [
  for i in range(startIndex, sessionHostCount): {
    parent: vms[i - startIndex]
    name: 'AADLoginForWindows'
    location: location
    properties: enrolWithIntune ? union(entraJoinProperties, entraJoinIntuneProperties) : entraJoinProperties
  }
]

// AVD agent and boot loader, then registration against the host pool.
resource avdAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [
  for i in range(startIndex, sessionHostCount): {
    parent: vms[i - startIndex]
    name: 'MicrosoftPowerShellDSC'
    location: location
    dependsOn: [
      entraJoin[i - startIndex]
    ]
    properties: {
      publisher: 'Microsoft.Powershell'
      type: 'DSC'
      typeHandlerVersion: '2.73'
      autoUpgradeMinorVersion: true
      settings: {
        modulesUrl: artifactsLocation
        configurationFunction: 'Configuration.ps1\\AddSessionHost'
        properties: {
          hostPoolName: hostPoolName
          // Tells the configuration this is an Entra-joined host. Omitting it
          // makes the agent assume AD DS and registration silently misbehaves.
          aadJoin: true
          UseAgentDownloadEndpoint: true
        }
      }
      protectedSettings: {
        properties: {
          registrationInfoToken: hostPool.listRegistrationTokens().value[0].token
        }
      }
    }
  }
]

// FSLogix and cloud Kerberos configuration, per host.
//
// Runs after the AVD agent so a failure here is attributable to this step
// rather than to registration. treatFailureAsDeploymentFailure is true: a host
// that silently keeps local profiles looks fine until a user's data vanishes on
// their second session.
resource fslogixConfiguration 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = [
  for i in range(startIndex, sessionHostCount): if (configureFslogix) {
    parent: vms[i - startIndex]
    name: 'Configure-Fslogix'
    location: location
    dependsOn: [
      avdAgent[i - startIndex]
    ]
    properties: {
      asyncExecution: false
      timeoutInSeconds: 600
      treatFailureAsDeploymentFailure: true
      parameters: [
        {
          name: 'VhdLocation'
          value: '\\\\${fslogixStorageAccountName}.file.${fileEndpointSuffix}\\${fslogixShareName}'
        }
        {
          name: 'ProfileSizeMB'
          value: string(fslogixProfileSizeMB)
        }
        {
          name: 'RestartAfterwards'
          value: string(restartAfterFslogixConfiguration)
        }
      ]
      source: {
        script: '''
          param(
            [string]$VhdLocation,
            [string]$ProfileSizeMB,
            [string]$RestartAfterwards
          )

          $ErrorActionPreference = 'Stop'

          # Cloud Kerberos ticket retrieval. Without this the host never asks
          # Entra ID for a Kerberos ticket, so it cannot authenticate to Azure
          # Files no matter how the storage account is configured. LSA reads it
          # at boot, which is why a restart follows.
          $kerberos = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters'
          New-Item -Path $kerberos -Force | Out-Null
          Set-ItemProperty -Path $kerberos -Name CloudKerberosTicketRetrievalEnabled -Value 1 -Type DWord

          # FSLogix profile containers.
          $fslogix = 'HKLM:\SOFTWARE\FSLogix\Profiles'
          New-Item -Path $fslogix -Force | Out-Null

          Set-ItemProperty -Path $fslogix -Name Enabled -Value 1 -Type DWord
          Set-ItemProperty -Path $fslogix -Name VHDLocations -Value @($VhdLocation) -Type MultiString
          Set-ItemProperty -Path $fslogix -Name SizeInMBs -Value ([int]$ProfileSizeMB) -Type DWord

          # VHDX rather than the VHD default: larger maximum, better resilience.
          Set-ItemProperty -Path $fslogix -Name VolumeType -Value 'vhdx' -Type String

          # Remove a local profile if a container should have applied, so a
          # user cannot silently end up with a local profile that disappears.
          Set-ItemProperty -Path $fslogix -Name DeleteLocalProfileWhenVHDShouldApply -Value 1 -Type DWord

          # Folder names as <username>_<SID> rather than <SID>_<username>, so
          # the share is readable by a human looking for one user's container.
          Set-ItemProperty -Path $fslogix -Name FlipFlopProfileDirectoryName -Value 1 -Type DWord

          Write-Output "FSLogix configured against $VhdLocation"
          Get-ItemProperty -Path $fslogix | Format-List | Out-String | Write-Output

          if ($RestartAfterwards -eq 'True') {
            Write-Output "Restarting in 120 seconds so LSA picks up cloud Kerberos."
            Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r', '/t', '120', '/c', 'FSLogix configuration' -NoNewWindow
          } else {
            Write-Output "Restart skipped. Cloud Kerberos will not take effect until this host reboots."
          }
        '''
      }
    }
  }
]

output vmNames array = [for i in range(startIndex, sessionHostCount): '${vmNamePrefix}-${i}']

@description('Name of the first session host in this pool. The NTFS permissions step runs here.')
output firstVmName string = '${vmNamePrefix}-${startIndex}'
