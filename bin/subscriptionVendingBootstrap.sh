#!/usr/bin/env bash
set -euo pipefail

MODE=""
SUBSCRIPTION_ID=""
SUBSCRIPTION_NAME=""
SOURCE_MANAGEMENT_GROUP_ID=""
TARGET_MANAGEMENT_GROUP_ID=""
DEPLOYMENT_PATH=""
BOOTSTRAP_RESOURCE_GROUP_NAME=""
BOOTSTRAP_MANAGED_IDENTITY_NAME=""
PROVIDER_GROUP=""
BOOTSTRAP_TEMPLATE_FILE=""
SERVICE_CONNECTION_NAME=""
AZURE_DEVOPS_ORGANIZATION_URL=""
AZURE_DEVOPS_PROJECT_NAME=""

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --mode) MODE="$2"; shift ;;
    --subscription-id) SUBSCRIPTION_ID="$2"; shift ;;
    --subscription-name) SUBSCRIPTION_NAME="$2"; shift ;;
    --source-management-group-id) SOURCE_MANAGEMENT_GROUP_ID="$2"; shift ;;
    --target-management-group-id) TARGET_MANAGEMENT_GROUP_ID="$2"; shift ;;
    --deployment-path) DEPLOYMENT_PATH="$2"; shift ;;
    --bootstrap-resource-group-name) BOOTSTRAP_RESOURCE_GROUP_NAME="$2"; shift ;;
    --bootstrap-managed-identity-name) BOOTSTRAP_MANAGED_IDENTITY_NAME="$2"; shift ;;
    --provider-group) PROVIDER_GROUP="$2"; shift ;;
    --bootstrap-template-file) BOOTSTRAP_TEMPLATE_FILE="$2"; shift ;;
    --service-connection-name) SERVICE_CONNECTION_NAME="$2"; shift ;;
    --azure-devops-project-name) AZURE_DEVOPS_PROJECT_NAME="$2"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

require_value() {
  local value="$1"
  local name="$2"
  if [[ -z "$value" ]]; then
    echo "Error: $name is required." >&2
    exit 1
  fi
}

subscription_in_management_group() {
  local management_group_id="$1"
  az rest \
    --method get \
    --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/${management_group_id}/subscriptions/${SUBSCRIPTION_ID}?api-version=2020-05-01" \
    --only-show-errors > /dev/null 2>&1
}

ensure_management_group_exists() {
  local management_group_id="$1"
  az account management-group show --name "$management_group_id" --only-show-errors > /dev/null
}

ensure_subscription_exists() {
  az account subscription show --id "$SUBSCRIPTION_ID" --query id -o tsv --only-show-errors > /dev/null
}

register_required_providers() {
  local providers
  providers=$(jq -r --arg group "$PROVIDER_GROUP" '.subscriptionProviders[] | select(.group == $group) | .providers[]' "parameters/subscriptionVending.json")

  if [[ -z "$providers" ]]; then
    echo "Error: no providers found for provider group '$PROVIDER_GROUP'." >&2
    exit 1
  fi

  az account set --subscription "$SUBSCRIPTION_ID"
  for provider in $providers; do
    local state
    state=$(az provider show --namespace "$provider" --query registrationState -o tsv --only-show-errors)
    echo "Provider '$provider' state: $state"
    if [[ "$state" != "Registered" ]]; then
      az provider register --namespace "$provider" --wait --only-show-errors
    fi
  done
}

validate_inputs() {
  require_value "$SUBSCRIPTION_ID" "--subscription-id"
  require_value "$SOURCE_MANAGEMENT_GROUP_ID" "--source-management-group-id"
  require_value "$TARGET_MANAGEMENT_GROUP_ID" "--target-management-group-id"
  require_value "$DEPLOYMENT_PATH" "--deployment-path"
  require_value "$BOOTSTRAP_RESOURCE_GROUP_NAME" "--bootstrap-resource-group-name"
  require_value "$BOOTSTRAP_MANAGED_IDENTITY_NAME" "--bootstrap-managed-identity-name"
  require_value "$PROVIDER_GROUP" "--provider-group"
  require_value "$BOOTSTRAP_TEMPLATE_FILE" "--bootstrap-template-file"

  ensure_subscription_exists

  if [[ ! -f "$BOOTSTRAP_TEMPLATE_FILE" ]]; then
    echo "Error: bootstrap template '$BOOTSTRAP_TEMPLATE_FILE' does not exist." >&2
    exit 1
  fi

  if ! subscription_in_management_group "$SOURCE_MANAGEMENT_GROUP_ID" && ! subscription_in_management_group "$TARGET_MANAGEMENT_GROUP_ID"; then
    echo "Error: subscription '$SUBSCRIPTION_ID' is neither in source MG '$SOURCE_MANAGEMENT_GROUP_ID' nor target MG '$TARGET_MANAGEMENT_GROUP_ID'." >&2
    exit 1
  fi

  if [[ -n "$SERVICE_CONNECTION_NAME" ]]; then
    require_value "$AZURE_DEVOPS_PROJECT_NAME" "--azure-devops-project-name"
  fi
}

prepare_subscription() {
  ensure_subscription_exists

  if [[ -n "$SUBSCRIPTION_NAME" ]]; then
    echo "Renaming subscription '$SUBSCRIPTION_ID' to '$SUBSCRIPTION_NAME'"
    az account subscription rename --id "$SUBSCRIPTION_ID" --name "$SUBSCRIPTION_NAME" --only-show-errors
  else
    echo "Skipping subscription rename."
  fi

  register_required_providers
}

move_subscription() {
  require_value "$SOURCE_MANAGEMENT_GROUP_ID" "--source-management-group-id"
  require_value "$TARGET_MANAGEMENT_GROUP_ID" "--target-management-group-id"

  ensure_subscription_exists
  ensure_management_group_exists "$SOURCE_MANAGEMENT_GROUP_ID"
  ensure_management_group_exists "$TARGET_MANAGEMENT_GROUP_ID"

  if subscription_in_management_group "$TARGET_MANAGEMENT_GROUP_ID"; then
    echo "Subscription '$SUBSCRIPTION_ID' is already in target MG '$TARGET_MANAGEMENT_GROUP_ID'."
    return 0
  fi

  if ! subscription_in_management_group "$SOURCE_MANAGEMENT_GROUP_ID"; then
    echo "Error: subscription '$SUBSCRIPTION_ID' is not in expected source MG '$SOURCE_MANAGEMENT_GROUP_ID'." >&2
    exit 1
  fi

  echo "Moving subscription '$SUBSCRIPTION_ID' to target MG '$TARGET_MANAGEMENT_GROUP_ID'"
  az account management-group subscription add --name "$TARGET_MANAGEMENT_GROUP_ID" --subscription "$SUBSCRIPTION_ID" --only-show-errors
}

deploy_bootstrap() {
  require_value "$BOOTSTRAP_RESOURCE_GROUP_NAME" "--bootstrap-resource-group-name"
  require_value "$BOOTSTRAP_MANAGED_IDENTITY_NAME" "--bootstrap-managed-identity-name"
  require_value "$DEPLOYMENT_PATH" "--deployment-path"
  require_value "$BOOTSTRAP_TEMPLATE_FILE" "--bootstrap-template-file"

  az account set --subscription "$SUBSCRIPTION_ID"
  az deployment sub create \
    --name "subvending-${SUBSCRIPTION_ID:0:8}-${BOOTSTRAP_RESOURCE_GROUP_NAME}" \
    --location "$DEPLOYMENT_PATH" \
    --template-file "$BOOTSTRAP_TEMPLATE_FILE" \
    --parameters \
      param_location="$DEPLOYMENT_PATH" \
      param_resourceGroupName="$BOOTSTRAP_RESOURCE_GROUP_NAME" \
      param_managedIdentityName="$BOOTSTRAP_MANAGED_IDENTITY_NAME" \
    --only-show-errors
}

assign_uami_rbac() {
  local params_file="parameters/subscriptionVending.json"

  az account set --subscription "$SUBSCRIPTION_ID"

  local principal_id
  principal_id=$(az identity show \
    --name "$BOOTSTRAP_MANAGED_IDENTITY_NAME" \
    --resource-group "$BOOTSTRAP_RESOURCE_GROUP_NAME" \
    --query principalId \
    -o tsv \
    --only-show-errors)

  if [[ -z "$principal_id" ]]; then
    echo "Error: bootstrap UAMI '$BOOTSTRAP_MANAGED_IDENTITY_NAME' not found in RG '$BOOTSTRAP_RESOURCE_GROUP_NAME'." >&2
    exit 1
  fi

  local scope="/subscriptions/$SUBSCRIPTION_ID"
  local role_count
  role_count=$(jq '.bootstrapUamiRoles | length' "$params_file")

  for (( i=0; i<role_count; i++ )); do
    local role_name condition condition_version existing
    role_name=$(jq -r ".bootstrapUamiRoles[$i].role" "$params_file")
    condition=$(jq -r ".bootstrapUamiRoles[$i].condition // empty" "$params_file")
    condition_version=$(jq -r ".bootstrapUamiRoles[$i].conditionVersion // empty" "$params_file")

    existing=$(az role assignment list \
      --assignee-object-id "$principal_id" \
      --scope "$scope" \
      --query "[?roleDefinitionName=='$role_name'] | [0].id" \
      -o tsv --only-show-errors)

    if [[ -n "$existing" ]]; then
      echo "Role '$role_name' already assigned to bootstrap UAMI."
      continue
    fi

    local cmd=(az role assignment create
      --assignee-object-id "$principal_id"
      --assignee-principal-type ServicePrincipal
      --role "$role_name"
      --scope "$scope"
      --only-show-errors)

    [[ -n "$condition" ]] && cmd+=(--condition "$condition" --condition-version "${condition_version:-2.0}")

    "${cmd[@]}"
    echo "Assigned role '$role_name' to bootstrap UAMI."
  done
}

prepare_service_connection_manifest() {
  require_value "$SERVICE_CONNECTION_NAME" "--service-connection-name"
  require_value "$AZURE_DEVOPS_PROJECT_NAME" "--azure-devops-project-name"

  local organization_url
  organization_url="${AZURE_DEVOPS_ORGANIZATION_URL:-${SYSTEM_COLLECTIONURI:-}}"
  require_value "$organization_url" "Azure DevOps organization URL (SYSTEM_COLLECTIONURI)"

  az account set --subscription "$SUBSCRIPTION_ID"

  local tenant_id client_id principal_id subscription_name output_dir output_file
  tenant_id=$(az account show --query tenantId -o tsv --only-show-errors)
  subscription_name=$(az account subscription show --id "$SUBSCRIPTION_ID" --query displayName -o tsv --only-show-errors)
  client_id=$(az identity show --name "$BOOTSTRAP_MANAGED_IDENTITY_NAME" --resource-group "$BOOTSTRAP_RESOURCE_GROUP_NAME" --query clientId -o tsv --only-show-errors)
  principal_id=$(az identity show --name "$BOOTSTRAP_MANAGED_IDENTITY_NAME" --resource-group "$BOOTSTRAP_RESOURCE_GROUP_NAME" --query principalId -o tsv --only-show-errors)

  output_dir="${PIPELINE_ARTIFACTSTAGINGDIRECTORY:-$(pwd)}"
  mkdir -p "$output_dir"
  output_file="$output_dir/service-connection-manifest.json"

  jq -n \
    --arg organizationUrl "$organization_url" \
    --arg projectName "$AZURE_DEVOPS_PROJECT_NAME" \
    --arg serviceConnectionName "$SERVICE_CONNECTION_NAME" \
    --arg subscriptionId "$SUBSCRIPTION_ID" \
    --arg subscriptionName "$subscription_name" \
    --arg tenantId "$tenant_id" \
    --arg resourceGroupName "$BOOTSTRAP_RESOURCE_GROUP_NAME" \
    --arg managedIdentityName "$BOOTSTRAP_MANAGED_IDENTITY_NAME" \
    --arg managedIdentityClientId "$client_id" \
    --arg managedIdentityPrincipalId "$principal_id" \
    '{
      organizationUrl: $organizationUrl,
      projectName: $projectName,
      serviceConnectionName: $serviceConnectionName,
      subscriptionId: $subscriptionId,
      subscriptionName: $subscriptionName,
      tenantId: $tenantId,
      resourceGroupName: $resourceGroupName,
      managedIdentityName: $managedIdentityName,
      managedIdentityClientId: $managedIdentityClientId,
      managedIdentityPrincipalId: $managedIdentityPrincipalId,
      authentication: {
        type: "OIDC to UAMI",
        note: "Use this manifest to create the Azure DevOps service connection using workload identity federation to the existing user-assigned managed identity."
      }
    }' > "$output_file"

  echo "Prepared service connection manifest at: $output_file"

  local pat="${AZURE_DEVOPS_EXT_PAT:-}"
  if [[ -z "$pat" ]]; then
    echo "AZURE_DEVOPS_EXT_PAT not set — skipping service connection creation. Create it manually using the manifest."
    return 0
  fi

  local project_id
  project_id=$(curl -sf \
    -H "Authorization: Bearer $pat" \
    "${organization_url}/_apis/projects/${AZURE_DEVOPS_PROJECT_NAME}?api-version=7.1" \
    | jq -r '.id')

  if [[ -z "$project_id" || "$project_id" == "null" ]]; then
    echo "Error: could not resolve project ID for '${AZURE_DEVOPS_PROJECT_NAME}'." >&2
    exit 1
  fi

  # Check if service connection already exists
  local existing_sc
  existing_sc=$(curl -sf \
    -H "Authorization: Bearer $pat" \
    "${organization_url}/${AZURE_DEVOPS_PROJECT_NAME}/_apis/serviceendpoint/endpoints?endpointNames=${SERVICE_CONNECTION_NAME}&api-version=7.1" \
    | jq -r '.value[0].id // empty')

  if [[ -n "$existing_sc" ]]; then
    echo "Service connection '${SERVICE_CONNECTION_NAME}' already exists (id: $existing_sc). Skipping creation."
    return 0
  fi

  local response http_code
  response=$(curl -s -o /tmp/sc_response.json -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $pat" \
    -H "Content-Type: application/json" \
    "${organization_url}/${AZURE_DEVOPS_PROJECT_NAME}/_apis/serviceendpoint/endpoints?api-version=7.1" \
    -d "$(jq -n \
      --arg subscriptionId "$SUBSCRIPTION_ID" \
      --arg subscriptionName "$subscription_name" \
      --arg tenantId "$tenant_id" \
      --arg clientId "$client_id" \
      --arg name "$SERVICE_CONNECTION_NAME" \
      --arg projectId "$project_id" \
      --arg projectName "$AZURE_DEVOPS_PROJECT_NAME" \
      '{
        data: {subscriptionId: $subscriptionId, subscriptionName: $subscriptionName, environment: "AzureCloud", scopeLevel: "Subscription", creationMode: "Manual"},
        name: $name,
        type: "azurerm",
        url: "https://management.azure.com/",
        authorization: {parameters: {tenantid: $tenantId, serviceprincipalid: $clientId}, scheme: "WorkloadIdentityFederation"},
        isShared: false,
        isReady: true,
        serviceEndpointProjectReferences: [{projectReference: {id: $projectId, name: $projectName}, name: $name}]
      }')")
  http_code="$response"

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    echo "Service connection '${SERVICE_CONNECTION_NAME}' created successfully."
  else
    echo "Error: failed to create service connection (HTTP $http_code):" >&2
    cat /tmp/sc_response.json >&2
    exit 1
  fi
}

verify_bootstrap_result() {
  ensure_subscription_exists

  az account set --subscription "$SUBSCRIPTION_ID"
  az group show --name "$BOOTSTRAP_RESOURCE_GROUP_NAME" --only-show-errors > /dev/null
  az identity show --name "$BOOTSTRAP_MANAGED_IDENTITY_NAME" --resource-group "$BOOTSTRAP_RESOURCE_GROUP_NAME" --only-show-errors > /dev/null

  if [[ -n "$SERVICE_CONNECTION_NAME" ]]; then
    echo "Service connection '$SERVICE_CONNECTION_NAME' manifest should have been created in the ConfigureDevOps stage."
  fi
}

verify_final_result() {
  require_value "$TARGET_MANAGEMENT_GROUP_ID" "--target-management-group-id"

  ensure_subscription_exists

  if ! subscription_in_management_group "$TARGET_MANAGEMENT_GROUP_ID"; then
    echo "Error: subscription '$SUBSCRIPTION_ID' is not in target MG '$TARGET_MANAGEMENT_GROUP_ID'." >&2
    exit 1
  fi
}

case "$MODE" in
  validate)
    validate_inputs
    ;;
  prepare)
    prepare_subscription
    ;;
  move)
    move_subscription
    ;;
  bootstrap)
    deploy_bootstrap
    ;;
  rbac)
    assign_uami_rbac
    ;;
  service-connection-manifest)
    prepare_service_connection_manifest
    ;;
  verify-bootstrap)
    verify_bootstrap_result
    ;;
  verify-final)
    verify_final_result
    ;;
  *)
    echo "Error: unsupported --mode '$MODE'." >&2
    exit 2
    ;;
esac