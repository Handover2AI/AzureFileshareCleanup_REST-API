# Azure FileShare Cleanup using REST API

![PSScriptAnalyzer](https://github.com/Handover2AI/AzureFileshareCleanup_REST-API/actions/workflows/ci-workflow-psscriptanalyzer.yml/badge.svg)

## 📌 Overview
This repository provides a PowerShell script to **delete files and directories from an Azure FileShare using the Azure Storage REST API**. Unlike [access key–based approache](https://github.com/Handover2AI/AzureFileshareCleanup_AccessKey), this method leverages direct REST calls for fine-grained control and can be integrated into automation pipelines or restricted environments where SDKs/CLI tools are not available.

---

## 🚀 Features
- The script acquires a Bearer token using either Managed Identity or user login (Connect-AzAccount).
- Recursively traverses directories until all eligible files are processed.
- It uses Azure Storage REST API (Invoke-RestMethod and Invoke-WebRequest) to list and delete files.
- Files are deleted if their Last-Modified timestamp is older than the cutoff.
- No Az.Storage or Az.Files modules are required — only Az.Accounts for token acquisition.
- Lightweight and dependency-free (no Az PowerShell modules required).
- Ideal for **automation jobs**, **restricted environments**, or **custom integrations**.

---

## ⚙️ Prerequisites
Before running the script, ensure you have:
- Proper **network access** to the Azure FileShare endpoint.
  - (https://<storageaccount>.file.core.windows.net/...). The Automation Account must be able to reach this endpoint. 
- **Azure Automation Account** with **PowerShell 7.2 runtime**
- **System-assigned managed identity** enabled for the Automation Account
- Managed identity assigned the following role on the storage account:
  - `Storage File Data Privileged Contributor`
- Az.Accounts module must be available in the Automation Account runtime (it is included by default in 7.2).
- If you set `$useManagedIdentity = $false`, then the script will use the logged-in user’s identity. In that case, the user must also have the same `Storage File Data Privileged Contributor` role on the storage account.

---

## 🔧 Configuration
The script defines the following parameters:

| Parameter            | Description                                                                 | Example Value             |
|----------------------|-----------------------------------------------------------------------------|---------------------------|
| `storageAccount`     | Name of the storage account                                                 | `stsamaks8dsc`            |
| `fileShare`          | Name of the file share                                                      | `fslogix`                 |
| `cutoffHours`        | Number of hours; files older than this will be deleted                      | `24`                      |
| `useManagedIdentity` | Use managed identity or logged in user's identity (interactive runs)        | `$true`                   |

---

## ▶️ Usage 
1. Import the script into your Automation Account as a **PowerShell runbook**.
2. Configure the runbook to use **PowerShell 7.2 runtime**.
3. Ensure the Automation Account’s managed identity has the required roles.
4. Set up a **schedule** to run the runbook daily (or at your desired frequency).

---

## 🤝 Contributing
Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to contribute.  
We expect all contributors to follow our [Code of Conduct](CODE_OF_CONDUCT.md).

---

## ✍️ Author
Created and maintained by **Handover2AI-byExistence**.   
If you find this useful, feel free to star ⭐ the repo or open issues for improvements.

---
