# macOS LAPS with Azure Key Vault – Deployment & Operations Guide

This README explains, end‑to‑end, how our macOS LAPS solution works and how to deploy and operate it correctly in Microsoft Intune with Azure Key Vault. It is written so that someone **outside the team** can follow it without prior context.

> **What this does (plain English):** On each Mac, we keep a hidden local admin account (default `LAPS_Admin`). On a schedule (e.g., weekly via Intune), we generate a strong random password, set it on the Mac, and upload the same password to **Azure Key Vault** under a device‑specific secret name. IT can then retrieve the password when needed.

---

## Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites & Assumptions](#prerequisites--assumptions)
3. [Azure Setup (one time)](#azure-setup-one-time)
4. [What to Configure in the Script](#what-to-configure-in-the-script)
5. [How the Script Works (step by step)](#how-the-script-works-step-by-step)
6. [Deploy with Microsoft Intune](#deploy-with-microsoft-intune)
7. [Verifying a Successful Run](#verifying-a-successful-run)
8. [How to Retrieve the Password](#how-to-retrieve-the-password)
9. [Troubleshooting Guide](#troubleshooting-guide)
10. [Security & Operational Practices](#security--operational-practices)
11. [Decommission / Cleanup](#decommission--cleanup)
12. [Appendix: Where to find IDs & Values](#appendix-where-to-find-ids--values)

---

## Architecture Overview

- **macOS device** runs a shell script as **root** (via Intune system context).
- Script ensures `jq` exists (JSON parser), creates/rotates local hidden admin, then requests an **OAuth token** from **Azure AD** using our App Registration (client ID/secret).
- Script **writes the local admin password** to **Azure Key Vault** as a **secret** named after the device (see *Secret naming* below).
- Helpdesk retrieves the secret from Key Vault when needed.

### Secret naming

- We store one secret **per device**. The secret name needs to be **Key Vault–safe** (letters, numbers, dashes only). macOS sometimes includes smart quotes in `ComputerName` (e.g., `Someone’s‑MacBook‑Air`). Our deployment sanitizes the name so Key Vault accepts it.

---

## Prerequisites & Assumptions

- **Microsoft Intune** manages the Macs (device already enrolled).
- You have an **Azure subscription** and permissions to:
  - Create a **Key Vault**.
  - Create an **App Registration** + client secret.
  - Assign **RBAC roles** on the Key Vault.
- macOS devices have **internet access** to:
  - `https://login.microsoftonline.com` (Azure AD)
  - `https://*.vault.azure.net` (Azure Key Vault)
- The script will run as **root** (Intune setting: *Run script as signed-in user* = **No**). This is required to create a local admin and to write to `/Library`.

---

## Azure Setup (one time)

### 1) Create the Key Vault

- Azure Portal → **Key Vaults** → **Create**
  - Name: e.g., `LAPSMacOS` (record as **KEYVAULT\_NAME**)
  - Access configuration: **Azure role-based access control (RBAC)**
  - Create.

### 2) App Registration

- Azure Portal → **Microsoft Entra ID (Azure AD)** → **App registrations** → **New registration**
  - Name: e.g., `MacOS-LAPS`
  - Supported account types: **Single tenant** (default is fine)
  - Register.
- On the Overview blade, record:
  - **Application (client) ID** → **AZURE\_CLIENT\_ID**
  - **Directory (tenant) ID** → **AZURE\_TENANT\_ID**
- **Certificates & secrets** → **New client secret**
  - Copy the **Value** immediately → **AZURE\_CLIENT\_SECRET** (store securely).

### 3) Grant the App access to the Key Vault (RBAC)

- Go to the Key Vault → **Access Control (IAM)** → **Add role assignment**
  - Role: **Key Vault Secrets Officer** (or **Secrets User** if write is not needed)
  - Assign access to: **User, group, or service principal**
  - Select the `` application (service principal) → Save.

> **Note:** RBAC assignments can take **up to \~10 minutes** to propagate.

---

## What to Configure in the Script

> You already have the scripts in the repo. This section explains *which values you must change* before deployment.

- `USERNAME` – the hidden local admin account (default `LAPS_Admin`).
- `KEYVAULT_NAME` – **only** the vault name (no URL). Example: `LAPSMacOS`.
- `AZURE_TENANT_ID` – from App Registration Overview.
- `AZURE_CLIENT_ID` – from App Registration Overview.
- `AZURE_CLIENT_SECRET` – from Certificates & secrets.
- **Secret naming (very important):** The script must use a **sanitized** device name for the Key Vault secret (to avoid curly quotes and spaces). We rely on either `LocalHostName` (already ASCII + dashes) or a sanitized `ComputerName`.
- **Password policy:** The script generates strong passwords (length, upper/lower/number/special) and sets it on the local admin. If your MDM enforces stricter policies, ensure the generator meets them (e.g., length ≥ 20).

---

## How the Script Works (step by step)

1. **Logging** – starts a timestamped log (by default in `/var/log/hidden_admin_setup.log` when run as root via Intune; or `~/Library/Logs` if you’re testing as a user).
2. **jq** – checks for `jq`; if missing, installs a static binary to `/usr/local/bin/jq`.
3. **Generate password** – builds a compliant random password.
4. **Create or rotate local admin**:
   - If `USERNAME` does not exist → creates it, adds to `admin` group, hides from login window.
   - If it exists → rotates the password.
   - (Recommended) Verifies the password with `dscl . -authonly` to ensure it really changed.
5. **Get Azure token** – obtains an access token using the App Registration (**client credentials grant**) with the resource `https://vault.azure.net`.
6. **Name the secret** – computes a Key Vault–safe secret name from the Mac’s name (sanitizing problematic characters, like curly apostrophes `’`).
7. **Write to Key Vault** – pushes the new password as a secret named after the device. If the secret exists, it overwrites it.
8. **Exit codes** – returns `0` on success; non‑zero on failure so Intune can flag errors. All steps are logged.

---

## Deploy with Microsoft Intune

### A) Create the script assignment

1. Intune admin center → **Devices → macOS → Shell scripts → Add**.
2. **Basics**
   - Name: `macOS LAPS – Password Rotate`
   - Description: Creates/rotates hidden admin and stores password in Azure Key Vault.
3. **Script settings**
   - **Upload** the script file from the repo (`laps_admin_setup.sh`).
   - **Run script as signed-in user**: **No** (runs as **root**; required).
   - **Hide script notifications on devices**: your choice.
   - **Script frequency**: choose **Every week** (or your rotation cadence).
   - **Max number of times to retry if script fails**: e.g., 2.
4. **Assignments**
   - Target a **device group** (recommended), not user group.

> **Why “Run as signed-in user = No”?** Creating local users, writing `/Library/Preferences`, and installing tools under `/usr/local/bin` require root. Running as a standard user will fail or prompt for `sudo` (which can’t be answered in Intune).

### B) Optional: Remove current GUI user from `admin`

- Upload the script (`admin_removal.sh`) as a **separate, one‑time** Intune script:
  - Run as signed-in user: **No**.
  - It detects the active GUI user (`/dev/console`) and removes them from `admin`, while **preserving** `root`, `LAPS_Admin`, and system accounts.

---

## Verifying a Successful Run

On the Mac (Terminal):

- **User exists & is admin**
  - `id LAPS_Admin` → should list `admin` in the groups.
  - `dscl . -read /Users/LAPS_Admin` → shows user record.
- **Hidden from login window**
  - `defaults read /Library/Preferences/com.apple.loginwindow HiddenUsersList` → should contain `LAPS_Admin`.
- **Password actually works** (optional but recommended)
  - `dscl . -authonly LAPS_Admin <PasswordFromKeyVault>` → returns no output and exit code 0 when correct.
- **Logs**
  - `/var/log/hidden_admin_setup.log` → contains a timestamped run summary and any errors.

In Azure:

- Go to the Key Vault → **Secrets** → look for a secret named after the device (sanitized). Open latest version → **Show Secret Value**.

---

## How to Retrieve the Password

### Azure Portal (GUI)

1. Key Vault → **Secrets** → select the device’s secret → select latest **version** → **Show Secret Value**.
2. You need **RBAC permission** on the vault (e.g., `Key Vault Secrets User`).

### Azure CLI (quick)

```bash
az login                 # or use a service principal
az keyvault secret show \
  --vault-name <KEYVAULT_NAME> \
  --name <SanitizedDeviceName> \
  --query value -o tsv
```

> If using the service principal (the same one as the script), authenticate with `az login --service-principal --username <CLIENT_ID> --password <CLIENT_SECRET> --tenant <TENANT_ID>` first.

---

## Troubleshooting Guide

### 1) **BadParameter** – invalid secret name

- Error: `The request URI contains an invalid name: Someone’s-MacBook-Air`.
- Cause: curly apostrophes or other non‑ASCII in `ComputerName`.
- Fix: Ensure the script sanitizes the device name (or uses `LocalHostName`). Re‑run. The secret should be created with the sanitized name, e.g., `Someones-MacBook-Air`.

### 2) **Token obtain error**

- Causes: wrong **tenant/client/secret**, **expired** client secret, Key Vault **firewall**, or **line breaks** in `curl` command when run via Intune.
- Fixes:
  - Use **single‑line** `curl` for the token request.
  - Log the raw token response to the log on failure to see `invalid_client` vs `unauthorized_client`.
  - Confirm the App has **Key Vault Secrets Officer** on **that vault’s scope**.
  - Wait up to **10 minutes** after new RBAC assignment.

### 3) Password in Key Vault doesn’t work on the Mac

- Causes:
  - Password **wasn’t actually set** locally (policy failure) but script continued.
  - Script ran **as user**, not root; `dscl`/`sysadminctl` failed silently.
- Fixes:
  - Run as **root** in Intune (signed‑in user = No); remove `sudo` if added - from inside the script.
  - After setting, **verify** with `dscl . -authonly <user> <pass>` before writing to Key Vault. Abort if verification fails.
  - If `dscl` returns `eDSAuthPasswordQualityCheckFailed`, either **increase password strength/length** or set via `sysadminctl` and then verify.

### 4) `eDSAuthPasswordQualityCheckFailed`

- The MDM or local policy rejected the password.
- Fix: Strengthen the generator (length 20+, include all character classes, avoid `laps`/`admin` in the password). If needed, set with `sysadminctl` and still verify with `authonly`.

### 5) `sudo: a terminal is required` / `Permission denied` writing logs

- You ran the script as a standard user. Intune must run it **as system**. Also, write logs to `/var/log` when in system context.

### 6) CRLF / `^M` / Quarantine

- If you see `bad interpreter: /bin/bash^M` or `unexpected end of file`, convert line endings to LF and clear quarantine (`xattr -d com.apple.quarantine <file>`).

### 7) Key Vault shows “Unauthorized by RBAC” for **you** in the portal

- That’s fine; the **service principal** the script uses can still access. To browse secrets in the portal with your user, assign yourself `Key Vault Secrets User` on the vault.

### 8) jq still present after cleanup

- If `jq --version` reports from `/usr/bin/jq`, that’s the **system** copy (SIP‑protected). It’s fine to leave. The script prefers `/usr/local/bin/jq` if installed there.

---

## Security & Operational Practices

- **Least privilege:** Only the service principal used by the script should have write access to the Key Vault. Helpdesk users should have **read‑only** (Secrets User).
- **Rotate** the App Registration **client secret** periodically (calendar a reminder). Update the Intune script with the new value.
- **Scope** the Intune assignment carefully (pilot first, then broader).
- **Logging:** Avoid writing the actual password to logs in production. Use the verification step (`authonly`) instead.
- **Naming:** Sanitized secret names don’t leak PII beyond device names. If you’re concerned, you can hash the hostname and store a mapping elsewhere (advanced).

---

## Decommission / Cleanup

When you retire a Mac or roll back this solution:

- **Delete** the device’s secret from Key Vault (or keep for audit, as policy dictates).
- Delete `LAPS_Admin`, clear `HiddenUsersList`, and remove the local `jq` binary if we installed it.

---

## Appendix: Where to find IDs & Values

| Variable              | Where to get it                                         | Example                                |
| --------------------- | ------------------------------------------------------- | -------------------------------------- |
| `KEYVAULT_NAME`       | Key Vault → Overview                                    | `LAPSMacOS`                            |
| `AZURE_TENANT_ID`     | App Registration → Overview → *Directory (tenant) ID*   | `aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee` |
| `AZURE_CLIENT_ID`     | App Registration → Overview → *Application (client) ID* | `11111111-2222-3333-4444-555555555555` |
| `AZURE_CLIENT_SECRET` | App Registration → Certificates & secrets → *Value*     | `*** keep secure ***`                  |

**CLI snippets (optional):**

- Who’s in the admin group: `dscl . -read /Groups/admin GroupMembership`
- Active GUI user: `stat -f%Su /dev/console`
- Verify password locally: `dscl . -authonly LAPS_Admin <password>`
- Get secret via CLI: `az keyvault secret show --vault-name <vault> --name <secret> --query value -o tsv`

---

### Contact & Contributions

- Open issues or PRs with improvements.
- This repo follows a simple MIT license; see `LICENSE`.

