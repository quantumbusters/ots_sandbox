// ============================================================
// nic-backend-assoc.bicep
//
// Standalone NIC update module to associate the capture VM's
// NIC with the ILB backend pool AFTER both the VM and the
// TAP/ILB are created — breaks the circular dependency.
// ============================================================
param captureNicName   string
param ilbBackendPoolId string
param captureSubnetId  string
param capturePrivateIp string
param publicIpId       string
param nsgId            string

resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' existing = {
  name: captureNicName
}

// Re-declare the NIC with the backend pool association added.
// Bicep requires the full properties block on update.
resource nicUpdate 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name:     captureNicName
  location: nic.location
  properties: {
    networkSecurityGroup: { id: nsgId }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress:          capturePrivateIp
          subnet:                    { id: captureSubnetId }
          publicIPAddress:           { id: publicIpId }
          loadBalancerBackendAddressPools: [
            { id: ilbBackendPoolId }
          ]
        }
      }
    ]
  }
}
