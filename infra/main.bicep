// ============================================================
// main.bicep v2 — adds VNet TAP module + wires ILB backend
// Deploy: az deployment group create -g tls-sandbox-rg -f main.bicep -p parameters.json
// ============================================================
targetScope = 'resourceGroup'

param location   string = resourceGroup().location
param env        string = 'sandbox'
param acrName    string = 'tlssandbox${uniqueString(resourceGroup().id)}'

@secure()
param adminSshKey       string
param offSiteWebhookUrl string

// ── Core modules (unchanged) ──────────────────────────────────
module network 'network.bicep' = {
  name: 'network'
  params: { location: location, env: env }
}

module registry 'acr.bicep' = {
  name: 'registry'
  params: { location: location, acrName: acrName }
}

module storage 'storage.bicep' = {
  name: 'storage'
  params: { location: location, env: env }
}

// ── Capture VM ────────────────────────────────────────────────
module captureVm 'capture-vm.bicep' = {
  name: 'captureVm'
  params: {
    location:            location
    env:                 env
    vnetId:              network.outputs.vnetId
    adminSshKey:         adminSshKey
    storageAccountName:  storage.outputs.storageAccountName
    offSiteWebhookUrl:   offSiteWebhookUrl
    runnerSubnetPrefix:  '10.10.1.0/24'
  }
  dependsOn: [ network ]
}

// ── VNet TAP + ILB ───────────────────────────────────────────
module tap 'vnet-tap.bicep' = {
  name: 'vnetTap'
  params: {
    location:         location
    env:              env
    captureSubnetId:  network.outputs.captureSubnetId
    captureNicId:     captureVm.outputs.captureNicId
  }
  dependsOn: [ captureVm ]
}

// ── Associate capture VM NIC → ILB backend pool ──────────────
// Done as a targeted NIC update to avoid circular dependency
// between capture-vm.bicep and vnet-tap.bicep
module nicBackend 'nic-backend-assoc.bicep' = {
  name: 'nicBackendAssoc'
  params: {
    captureNicName:    captureVm.outputs.captureNicName
    ilbBackendPoolId:  '${tap.outputs.ilbId}/backendAddressPools/capture-vm-pool'
    captureSubnetId:   network.outputs.captureSubnetId
    capturePrivateIp:  captureVm.outputs.captureVmPrivateIp
    publicIpId:        captureVm.outputs.capturePublicIpId
    nsgId:             captureVm.outputs.captureNsgId
  }
  dependsOn: [ tap ]
}

// ── Outputs ───────────────────────────────────────────────────
output acrLoginServer    string = registry.outputs.loginServer
output runnerSubnetId    string = network.outputs.subnetId
output captureSubnetId   string = network.outputs.captureSubnetId
output captureVmPublicIp string = captureVm.outputs.captureVmPublicIp
output captureVmName     string = captureVm.outputs.captureVmName
output captureNicId      string = captureVm.outputs.captureNicId
output tapId             string = tap.outputs.tapId
output tapName           string = tap.outputs.tapName
output storageAccount    string = storage.outputs.storageAccountName
output lawWorkspaceId    string = storage.outputs.lawWorkspaceId
