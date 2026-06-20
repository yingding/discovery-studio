// Stage 3 — Workspace, Chat Model, Discovery Storage Container, Project
// Depends on Stages 1 and 2 (references VNet, UAMI, Supercomputer, Storage Account by name).

@description('Naming prefix used in earlier stages — must match.')
param prefix string = 'disc-yw'

@description('Azure region.')
@allowed([
  'eastus'
  'eastus2'
  'swedencentral'
  'uksouth'
])
param location string = 'swedencentral'

@description('Tags applied to every resource in this stage.')
param tags object = {
  purpose: 'discovery'
}

@description('Storage account name produced by Stage 2 (output: storageAccountName).')
param storageAccountName string

@description('Chat model format.')
param chatModelFormat string = 'OpenAI'

@description('Chat model to deploy. Set to empty string to skip chat model deployment. Examples: gpt-5-mini, gpt-5-nano, gpt-5.2, gpt-5.4.')
param chatModelName string = 'gpt-5-mini'

@description('Name of the chat model deployment inside the workspace. Defaults to a sanitized chatModelName (dots -> hyphens, max 24 chars). Override if you want a custom alias.')
@maxLength(24)
param chatModelDeploymentName string = take(replace(empty(chatModelName) ? 'chat' : chatModelName, '.', '-'), 24)

// --- Derived names -----------------------------------------------------------
var vnetName = 'vnet-${prefix}'
var managedIdentityName = 'uami-${prefix}'
var supercomputerName = 'sc-${prefix}'
var workspaceName = 'ws-${prefix}'
var storageContainerName = 'stc-${prefix}'
var projectName = 'prj-${prefix}'

// References to resources from earlier stages.
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: managedIdentityName
}
resource supercomputer 'Microsoft.Discovery/supercomputers@2026-06-01' existing = {
  name: supercomputerName
}
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource workspace 'Microsoft.Discovery/workspaces@2026-06-01' = {
  name: workspaceName
  location: location
  tags: union(tags, {
    version: 'v2'
  })
  properties: {
    workspaceIdentity: {
      id: managedIdentity.id
    }
    supercomputerIds: [
      supercomputer.id
    ]
    agentSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'agentSubnet')
    privateEndpointSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'privateEndpointSubnet')
    workspaceSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'workspaceSubnet')
  }
}

resource chatModelDeployment 'Microsoft.Discovery/workspaces/chatModelDeployments@2026-06-01' = if (!empty(chatModelName)) {
  parent: workspace
  name: chatModelDeploymentName
  location: location
  tags: tags
  properties: {
    modelFormat: chatModelFormat
    modelName: chatModelName
  }
}

resource discoveryStorageContainer 'Microsoft.Discovery/storageContainers@2026-06-01' = {
  name: storageContainerName
  location: location
  tags: tags
  properties: {
    storageStore: {
      kind: 'AzureStorageBlob'
      storageAccountId: storageAccount.id
    }
  }
}

resource project 'Microsoft.Discovery/workspaces/projects@2026-06-01' = {
  parent: workspace
  name: projectName
  location: location
  tags: tags
  properties: {
    storageContainerIds: [
      discoveryStorageContainer.id
    ]
  }
  // V2 projects require an existing ChatModelDeployment in 'Succeeded' state
  // on the parent workspace. Bicep doesn't infer this dependency because the
  // project resource has no symbolic reference to chatModelDeployment, so
  // make it explicit — otherwise the project create can fire before the
  // chat model finishes and fail with:
  //   "Cannot create a V2 project: no ChatModelDeployment in Succeeded state
  //    found in workspace '<ws>'."
  // Only emit the dependsOn when the chat model is actually being deployed
  // (chatModelName non-empty); if the user skipped the chat model, the
  // project create will fail by design and the user must add one first.
  dependsOn: empty(chatModelName) ? [] : [
    chatModelDeployment
  ]
}

output workspaceName string = workspace.name
output workspaceId string = workspace.id
output projectId string = project.id
output storageContainerId string = discoveryStorageContainer.id
