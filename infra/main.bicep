// ============================================================
// main.bicep — TLS Regression Sandbox
// Deploy: az deployment group create -g tls-sandbox-rg -f main.bicep
// ============================================================
targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Short environment tag used in all resource names')
param env string = 'sandbox'

@description('Your ACR login server after build (populated post-deploy)')
param acrName string = 'tlssandbox${uniqueString(resourceGroup().id)}'

// ── Modules ──────────────────────────────────────────────────
module network 'network.bicep' = {
  name: 'network'
  params: {
    location: location
    env: env
  }
}

module registry 'acr.bicep' = {
  name: 'registry'
  params: {
    location: location
    acrName: acrName
  }
}

module storage 'storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    env: env
  }
}

// ── Outputs ───────────────────────────────────────────────────
output acrLoginServer string = registry.outputs.loginServer
output subnetId       string = network.outputs.subnetId
output storageAccount string = storage.outputs.storageAccountName
output lawWorkspaceId string = storage.outputs.lawWorkspaceId