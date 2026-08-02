# Azure Subscription Vending

Azure DevOps pipeline for automated subscription provisioning and placement within the Management Group hierarchy.

## What it does

1. Validates the subscription and input parameters
2. Renames the subscription and registers required resource providers
3. Deploys bootstrap resources (Resource Group + User Assigned Managed Identity) via Bicep
4. Assigns roles to the bootstrap UAMI on the subscription scope
5. Creates an Azure DevOps Service Connection for the new subscription *(optional)*
6. Moves the subscription to the target Management Group
7. Verifies final placement

## Repository structure

```
.pipelines/subscriptionVending.yml    # Azure DevOps pipeline
bin/subscriptionVending.sh            # Subscription vending script (bash)
bicep/bootstrap.bicep                 # Bicep template for bootstrap resources
parameters/subscriptionVending.json   # Provider registration groups and UAMI role definitions
```

## Prerequisites

- Azure DevOps Managed Pool with a dedicated UAMI
- UAMI assigned **Management Group Contributor** on the Root Management Group
- UAMI assigned **Contributor** and **User Access Administrator** on the staging Management Group
- `[ProjectName] Build Service` account added to **Endpoint Creators** in the target Azure DevOps project

## Running the pipeline

The subscription must be placed in the staging Management Group before the pipeline is triggered. The pipeline moves it to the target Management Group as the final step.

Required and optional parameters:

| Parameter | Description |
| --- | --- |
| `SubscriptionId` | ID of the subscription to provision |
| `SubscriptionName` | New subscription name. |
| `SourceManagementGroupId` | Staging MG where the subscription currently resides |
| `TargetManagementGroupId` | Target MG the subscription will be moved to |
| `BootstrapResourceGroupName` | Name for the bootstrap Resource Group |
| `BootstrapManagedIdentityName` | Name for the bootstrap UAMI |
| `ServiceConnectionName` | Name for the Azure DevOps Service Connection |
| `AzureDevOpsProjectName` | Target Azure DevOps project |
| `CreateServiceConnection` | Whether to create the Service Connection automatically (default: `true`) |

---

## 1. Purpose

Automated Azure subscription creation with a minimal set of resources and placement in the correct Management Group.

Prerequisites:

- A dedicated Management Group branch for empty/staging subscriptions is required. The pipeline performs bootstrap operations and RBAC assignments within this branch.

## 2. Pipeline actions and requirements

The pipeline runs on an Azure DevOps Managed Pool with a dedicated UAMI (User Assigned Managed Identity). The UAMI performs Azure (ARM) operations. Azure DevOps API operations are executed with `$(System.AccessToken)` under the project's Build Service identity.

Pipeline scope:

- creates and prepares the new subscription,
- performs bootstrap (RG, UAMI, roles),
- moves the subscription in the Management Group hierarchy,
- creates a Service Connection in Azure DevOps for the new subscription.

Requirements:

| Area | Requirement |
| --- | --- |
| Azure RBAC (Root MG) | permission to move subscriptions to the target MG branch |
| Azure RBAC (staging MG branch) | permission to create resources and perform bootstrap |
| Azure RBAC (staging MG branch) | permission to assign Contributor and User Access Administrator roles |
| Azure RBAC (assignment quality) | User Access Administrator must be unconstrained: "Allow user to assign all roles (highly privileged)" |
| Azure DevOps (project) | permission to create a Service Connection for the new subscription |

## 3. Pipeline stage order

The target stage order (MOVE at the end):

| Order | Stage | Script mode | What it does |
| --- | --- | --- | --- |
| 1 | ValidateInput | `validate` | Validates input and state: parameters, subscription existence, source/target MG existence, Bicep file presence, checks whether subscription is in source or target MG. |
| 2 | PrepareSubscription | `prepare` | Renames the subscription (optional) and registers providers from `parameters/subscriptionVending.json`. |
| 3 | BootstrapAzure | `bootstrap` | Deploys `bicep/bootstrap.bicep` at subscription scope: creates bootstrap RG and UAMI. |
| 4 | ConfigureAccess | `rbac` | Assigns roles to the bootstrap UAMI on subscription scope (`/subscriptions/<id>`). Roles are defined in `parameters/subscriptionVending.json`. |
| 5 | ConfigureDevOps *(optional)* | `service-connection-manifest` | Prepares and publishes `service-connection-manifest.json` artifact for Service Connection creation (OIDC to UAMI). **Requires the pipeline Build Service account to have Endpoint Creators permissions in the Azure DevOps project.** If not available, set `CreateServiceConnection=false` — the operator creates the Service Connection manually using bootstrap data (subscription ID, UAMI client ID, tenant ID). The `service-connection-manifest.json` file is available as a pipeline artifact (`subscription-vending-service-connection`) under the Artifacts tab of the pipeline run. |
| 6 | VerifyBootstrap | `verify-bootstrap` | Verifies bootstrap state: bootstrap RG and UAMI exist. |
| 7 | FinalMove | `move` | Moves the subscription to the target MG. |
| 8 | VerifyFinal | `verify-final` | Verifies the subscription is in the target MG. |

## 4. Step-by-step: granting RBAC roles for the pipeline UAMI

**Goal: fulfill the RBAC requirements from section 2 so the pipeline can perform provisioning, bootstrap, and the final subscription move.**

Roles to assign:

- Management Group Contributor on the Root MG
- Contributor on the staging MG branch
- User Access Administrator on the staging MG branch

## 4.1 Gather required values

- `SUBSCRIPTION_ID` — subscription ID where the pipeline will operate
- `UAMI_RESOURCE_GROUP` — Resource Group where the UAMI will be created
- `UAMI_NAME` — e.g. `id-uami-subscription-vending`
- `PRINCIPAL_ID` — principalId of the created UAMI
- `ROOT_MG_ID` — Root Management Group ID
- `EMPTY_SUBSCRIPTIONS_MG_ID` — staging MG branch ID
- `LOCATION` — e.g. `germanywestcentral`

## 4.2 Create the UAMI

```bash
az identity create --name <UAMI_NAME> --resource-group <UAMI_RESOURCE_GROUP> --location <LOCATION>

az identity show --name <UAMI_NAME> --resource-group <UAMI_RESOURCE_GROUP> --query principalId -o tsv
```

Portal steps:

1. Open the Resource Group in the Azure portal
2. Click **Create**
3. Search for **User Assigned Managed Identity** and click Create
4. Fill in Name and Region, click **Review + create**, then **Create**
5. Open the created UAMI and copy the **Principal ID**

## 4.3 Assign role on Root MG

```bash
az role assignment create --assignee-object-id <PRINCIPAL_ID> --assignee-principal-type ServicePrincipal --role "Management Group Contributor" --scope "/providers/Microsoft.Management/managementGroups/<ROOT_MG_ID>"
```

Portal steps:

1. Open **Management Groups** in the Azure portal
2. Select the Root MG
3. Go to **Access Control (IAM)**
4. Click **Add role assignment**
5. Select **Management Group Contributor**
6. Set **Assign access to** → **Managed identity**
7. Select the created UAMI
8. Click **Review + assign**

## 4.4 Assign roles on the staging MG branch

```bash
az role assignment create --assignee-object-id <PRINCIPAL_ID> --assignee-principal-type ServicePrincipal --role "Contributor" --scope "/providers/Microsoft.Management/managementGroups/<EMPTY_SUBSCRIPTIONS_MG_ID>"

az role assignment create --assignee-object-id <PRINCIPAL_ID> --assignee-principal-type ServicePrincipal --role "User Access Administrator" --scope "/providers/Microsoft.Management/managementGroups/<EMPTY_SUBSCRIPTIONS_MG_ID>"
```

Portal steps:

1. Open the staging MG branch in the Azure portal
2. Go to **Access Control (IAM)**
3. Click **Add role assignment**
4. Select **Contributor**, assign to the UAMI
5. Click **Review + assign**
6. Repeat steps 2–5 for **User Access Administrator**
7. Ensure the User Access Administrator assignment is set to **"Allow user to assign all roles (highly privileged)"** (no conditions/restrictions)

## 4.5 Verify assignments

```bash
az role assignment list --assignee-object-id <PRINCIPAL_ID> --all --query "[].{role:roleDefinitionName,scope:scope}" -o table
```

Expected result:

- Management Group Contributor on Root MG
- Contributor on the staging MG branch
- User Access Administrator on the staging MG branch

## 5. Azure DevOps permissions

**Goal: allow the pipeline to create a Service Connection for the newly provisioned subscription.**

### 5.1 Identity that creates the Service Connection

The pipeline creates the Service Connection via the Azure DevOps REST API using `$(System.AccessToken)`. This token represents the **project's built-in build service account** — not the UAMI from the Managed Pool.

The account name follows this format:
```
<ProjectName> Build Service (<OrgName>)
```

> **Note:** The UAMI attached to the Managed Pool is used for Azure (ARM) operations. For Azure DevOps API operations, the pipeline uses `$(System.AccessToken)` — a separate identity.

### 5.2 Grant Endpoint Creators permission

The minimum required permission is **`Endpoint Creators`** — not Project Administrators. It grants the right to create and view Service Connections in the project.

For each Azure DevOps project where the pipeline creates Service Connections:

1. Open the Azure DevOps project.
2. Go to **Project settings → Service connections**.
3. Click **Security** (padlock icon, top right).
4. Find the **Endpoint Creators** group.
5. Click **Add** and search for `<ProjectName> Build Service (<OrgName>)`.
6. Save changes.

Verification: the Build Service account is visible in the Endpoint Creators group.

### 5.3 New projects

Each time a new Azure DevOps project is created where the vending pipeline will run, repeat step 5.2 — add that project's Build Service account to its Endpoint Creators group.

### 5.4 Verify

```bash
az devops security group membership list \
  --group-id "[<PROJECT_NAME>]\Endpoint Creators" \
  --org "https://dev.azure.com/<ORG_NAME>" \
  --query "[].principalName" -o table
```

Expected result: `<ProjectName> Build Service (<OrgName>)` visible in the list.

## 6. Pre-run checklist

- dedicated UAMI exists
- Management Group Contributor assigned on Root MG
- Contributor and User Access Administrator assigned on the staging MG branch
- User Access Administrator assignment is set to "Allow user to assign all roles (highly privileged)" (no conditions)
- **`<ProjectName> Build Service (<OrgName>)`** added to **Endpoint Creators** in every Azure DevOps project where the pipeline creates Service Connections
- pipeline stage order matches the RBAC model

## Notes

- During development, AI tools (GitHub Copilot and Claude Code) were used to support research, drafting, and documentation, while architecture decisions, validation, and final implementation choices were made by the author.
