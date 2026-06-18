// Stage 1 — Networking
// Creates the VNet + 6 subnets required by Microsoft Discovery.

@description('Naming prefix used for all resources (e.g. "disc-yw").')
param prefix string = 'disc-yw'

@description('Azure region. Must be a Discovery-supported region.')
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

// --- VNet / subnet customization ---------------------------------------------
param vnetAddressPrefix string = '10.0.0.0/16'
param supercomputerNodepoolSubnetPrefix string = '10.0.1.0/24'
param aksSubnetPrefix string = '10.0.2.0/24'
param workspaceSubnetPrefix string = '10.0.3.0/24'
param privateEndpointSubnetPrefix string = '10.0.4.0/24'
param agentSubnetPrefix string = '10.0.5.0/24'
param searchSubnetPrefix string = '10.0.6.0/24'

var vnetName = 'vnet-${prefix}'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'supercomputerNodepoolSubnet'
        properties: {
          addressPrefix: supercomputerNodepoolSubnetPrefix
        }
      }
      {
        name: 'aksSubnet'
        properties: {
          addressPrefix: aksSubnetPrefix
        }
      }
      {
        name: 'workspaceSubnet'
        properties: {
          addressPrefix: workspaceSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'privateEndpointSubnet'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
        }
      }
      {
        name: 'agentSubnet'
        properties: {
          addressPrefix: agentSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'searchSubnet'
        properties: {
          addressPrefix: searchSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

@description('Name of the deployed VNet (passed to later stages).')
output vnetName string = vnet.name
output vnetId string = vnet.id
