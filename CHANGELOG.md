# Changelog

Template spec versions are **not** immutable — Microsoft's guidance is that you
can update an existing version for hotfixes or publish a new one, and the
version is just a text string. So day-to-day iteration publishes over `dev`:

```
.\scripts\publish-templatespec.ps1 -Location <region>
```

A numbered version is cut only when there is something worth keeping, and
recorded below. **1.0.0 is reserved for the first release fit to put in front
of a customer**, which this is not yet.

## 0.3 — current

Everything below has been built. Only the first group has been run against
Azure.

**Fixed since the last deployment attempt**

- AVD Insights and the disk-space alert failed on a brand new Log Analytics
  workspace with `InvalidOutputTable`. The `Perf` and `Event` built-in tables
  do not exist until something writes to them, so a data collection rule
  created seconds after the workspace has nothing to bind to. The workspace
  module now declares both tables explicitly, and the DCR and alerts consume
  that output so the dependency is real rather than incidental.
- The session host local administrator username was marked `@secure()`, which
  made ARM drop it from `osProfile` and fail the VM with
  `adminUsername is missing (null)`. Secure parameters are for secrets, and a
  username is not one.
- A subnet whose parent spoke does not match any spoke in the Spokes grid used
  to fail mid-deployment with `ResourceGroupNotFound`, after other resources
  had already been created. The deployment now reports the mismatch up front in
  the `subnetsWithUnknownSpoke` output.

**Deployed and verified**

- Hub and spoke networks, NSGs, route tables, NAT gateway, peerings
- FSLogix storage account with private endpoint and privatelink DNS
- Log Analytics with VNet, storage and control plane diagnostics
- Host pools, application groups, workspace
- Session hosts: gallery image, Entra join, host pool registration, sign-in
  role assignments
- Entra automation: bootstrap identity, group creation, Entra Kerberos admin
  consent and the cloud group SIDs tag

**Built, not yet run against Azure**

- Azure Firewall with a policy carrying the documented AVD egress rules
- AVD Insights — Azure Monitor Agent and a data collection rule
- Action group and six alerts
- FSLogix profile container configuration and cloud Kerberos on each host
- NTFS permissions on the share root via `Set-Acl`
- Published desktop rename, replacing "SessionDesktop"
- Tags, session host time zone and time zone redirection
- OS disk size

**Known not working**

- FSLogix profile containers do not mount. Leading theory is tenant-wide MFA
  enforcement, which Entra Kerberos does not support and which cannot be
  excluded per application without Conditional Access. Unproven.

## 0.2

- Session hosts, Entra ID automation, the Entra ID wizard tab.

## 0.1

- First working landing zone: hub, spokes, storage, monitoring and the AVD
  control plane, deployed end to end from the portal wizard.
