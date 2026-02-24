// ============================================================
// network.bicep — Dual-stack VNet for ACI runners
// IPv4: 10.10.0.0/16   IPv6: ace:cab:deca::/48
// ============================================================
param location string
param env string

var vnetName   = 'vnet-tls-${env}'
var subnetName = 'snet-runners'

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.10.0.0/16'
        'ace:cab:deca::/48'       // IPv6 ULA prefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefixes: [
            '10.10.1.0/24'
            'ace:cab:deca:deed::/64'
          ]
          // ACI requires subnet delegation
          delegations: [
            {
              name: 'aciDelegation'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
    ]
  }
}

// NAT Gateway for deterministic egress IP (both IPv4 + IPv6)
resource pip4 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: 'pip-nat-ipv4-${env}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource pip6 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: 'pip-nat-ipv6-${env}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv6'
  }
}

resource natGw 'Microsoft.Network/natGateways@2023-04-01' = {
  name: 'ng-tls-${env}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      { id: pip4.id }
    ]
    publicIpPrefixes: []   // add IPv6 prefix resource if needed
  }
}

// Attach NAT GW to subnet
resource subnetUpdate 'Microsoft.Network/virtualNetworks/subnets@2023-04-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefixes: [
      '10.10.1.0/24'
      'ace:cab:deca:deed::/64'
    ]
    natGateway: { id: natGw.id }
    delegations: [
      {
        name: 'aciDelegation'
        properties: {
          serviceName: 'Microsoft.ContainerInstance/containerGroups'
        }
      }
    ]
  }
  dependsOn: [ vnet ]
}

output subnetId string = '${vnet.id}/subnets/${subnetName}'
output vnetId   string = vnet.id
