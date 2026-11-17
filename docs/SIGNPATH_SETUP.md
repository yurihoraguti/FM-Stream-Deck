# Maintainer guide: signing releases with SignPath Foundation

The workflow signs `FMStreamDeck.exe` automatically on `v*` tags once SignPath is configured. Until then, releases are built unsigned.

## 1. Apply

1. Make sure the repository has at least one published release (SignPath requires the software to be already released).
2. Enable multi-factor authentication on your GitHub account.
3. Apply at <https://signpath.org/apply> with the repository URL `https://github.com/yurihoraguti/FM-Stream-Deck` and the policy page [`CODE_SIGNING.md`](../CODE_SIGNING.md).
4. After approval, sign in to SignPath (with MFA) and install the **SignPath GitHub App** on this repository if asked.

## 2. Configure the SignPath project

In the SignPath web app:

- **Project slug:** `fm-stream-deck` (or any slug; set it as a variable below).
- **Signing policy:** `release-signing`, with manual approval by the approver listed in `CODE_SIGNING.md`.
- **Trusted build system:** GitHub.com, linked to this repository.
- **Artifact configuration** (the workflow uploads a ZIP that contains the executable):

```xml
<?xml version="1.0" encoding="utf-8"?>
<artifact-configuration xmlns="http://signpath.io/artifact-configuration/v1">
  <zip-file>
    <pe-file path="FMStreamDeck.exe" product-name="FM-Stream Deck" product-version="1.0.0.0">
      <authenticode-sign />
    </pe-file>
  </zip-file>
</artifact-configuration>
```

> `product-name` and `product-version` must match the executable metadata (`AssemblyProduct` and `AssemblyFileVersion` in `server/FMStreamDeck.cs`). Update both together on each version bump.

## 3. Configure the GitHub repository

**Settings → Secrets and variables → Actions**

| Kind | Name | Value |
|---|---|---|
| Secret | `SIGNPATH_API_TOKEN` | API token of a SignPath user with *submitter* permission |
| Variable | `SIGNPATH_ORGANIZATION_ID` | your SignPath organization ID |
| Variable | `SIGNPATH_PROJECT_SLUG` | `fm-stream-deck` (optional, this is the default) |
| Variable | `SIGNPATH_SIGNING_POLICY_SLUG` | `release-signing` (optional, this is the default) |

## 4. Release

```bash
git tag v1.0.1
git push origin v1.0.1
```

The workflow builds the executable, submits it to SignPath and **waits for your approval** (up to 2 hours) in the SignPath web app. After that it packages the signed executable and publishes the GitHub release.

Then remove the "Status: pending" note from `CODE_SIGNING.md`.
