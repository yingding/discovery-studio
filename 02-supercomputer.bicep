// Stage 2 — Identity, Storage, RBAC, Supercomputer + Node Pool
// Depends on Stage 1 (references the VNet by name).

@description('Naming prefix used in Stage 1 — must match.')
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

// --- Node pool customization -------------------------------------------------
@description('VM SKU. Examples: Standard_D4s_v6, Standard_NC4as_T4_v3, Standard_NC24ads_A100_v4.')
param nodePoolVmSize string = 'Standard_NC4as_T4_v3'

@minValue(0)
param nodePoolMinNodeCount int = 0

@minValue(1)
param nodePoolMaxNodeCount int = 1

@allowed([
  'Regular'
  'Spot'
])
param nodePoolScaleSetPriority string = 'Regular'

// --- Derived names -----------------------------------------------------------
var vnetName = 'vnet-${prefix}'
var managedIdentityName = 'uami-${prefix}'
var supercomputerName = 'sc-${prefix}'
var nodePoolName = 'np1'
// Storage account: 3-24 lowercase alphanumeric, globally unique.
var storageAccountName = toLower('stg${replace(prefix, '-', '')}${take(uniqueString(resourceGroup().id), 8)}')
var blobContainerName = 'discoveryoutputs'

// Built-in role definition IDs
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var discoveryPlatformContributorRoleId = '01288891-85ee-45a7-b367-9db3b752fc65'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// Reference the VNet from Stage 1.
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: managedIdentityName
  location: location
  tags: tags
  properties: {
    isolationScope: 'Regional'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    cors: {
      corsRules: [
        {
          allowedOrigins: [
            'https://studio.discovery.microsoft.com'
            'https://*.vscode-cdn.net'
            'https://vscode.dev'
          ]
          allowedMethods: [
            'GET'
            'HEAD'
            'DELETE'
            'PUT'
          ]
          allowedHeaders: [
            '*'
          ]
          exposedHeaders: [
            '*'
          ]
          maxAgeInSeconds: 200
        }
      ]
    }
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: blobContainerName
}

resource storageBlobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, managedIdentity.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource discoveryPlatformContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, discoveryPlatformContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', discoveryPlatformContributorRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, acrPullRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource supercomputer 'Microsoft.Discovery/supercomputers@2026-06-01' = {
  name: supercomputerName
  location: location
  tags: union(tags, {
    version: 'v2'
  })
  properties: {
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'aksSubnet')
    identities: {
      clusterIdentity: {
        id: managedIdentity.id
      }
      kubeletIdentity: {
        id: managedIdentity.id
      }
      workloadIdentities: {
        '${managedIdentity.id}': {}
      }
    }
  }
}

resource nodePool 'Microsoft.Discovery/supercomputers/nodePools@2026-06-01' = {
  parent: supercomputer
  name: nodePoolName
  location: location
  tags: tags
  properties: {
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'supercomputerNodepoolSubnet')
    vmSize: nodePoolVmSize
    maxNodeCount: nodePoolMaxNodeCount
    minNodeCount: nodePoolMinNodeCount
    scaleSetPriority: nodePoolScaleSetPriority
  }
}

output managedIdentityName string = managedIdentity.name
output managedIdentityId string = managedIdentity.id
output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output supercomputerName string = supercomputer.name
output supercomputerId string = supercomputer.id
output nodePoolId string = nodePool.id
