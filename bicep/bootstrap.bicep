targetScope = 'subscription'

@description('Azure region for the bootstrap resource group and managed identity.')
param param_location string

@description('Name of the bootstrap resource group.')
param param_resourceGroupName string

@description('Name of the bootstrap user-assigned managed identity.')
param param_managedIdentityName string

@description('Lock configuration for the bootstrap resource group.')
param param_resourceGroupLock object = {}

@description('Tags applied to the bootstrap resource group and bootstrap identity.')
param param_tags object = {}

module module_resourceGroup 'br/public:avm/res/resources/resource-group:0.4.3' = {
  name: 'subvending-rg-${param_resourceGroupName}'
  params: {
    name: param_resourceGroupName
    location: param_location
    lock: param_resourceGroupLock
    tags: param_tags
  }
}

resource resource_bootstrapResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: param_resourceGroupName
}

module module_uami 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'subvending-uami-${param_managedIdentityName}'
  scope: resource_bootstrapResourceGroup
  params: {
    name: param_managedIdentityName
    location: param_location
    tags: param_tags
  }
  dependsOn: [
    module_resourceGroup
  ]
}

output output_resourceGroupName string = resource_bootstrapResourceGroup.name
output output_managedIdentityResourceId string = module_uami.outputs.resourceId
output output_managedIdentityPrincipalId string = module_uami.outputs.principalId
output output_managedIdentityClientId string = module_uami.outputs.clientId
