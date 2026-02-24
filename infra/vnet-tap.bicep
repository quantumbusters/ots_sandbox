// ============================================================
// vnet-tap.bicep
//
// Azure Virtual Network TAP mirrors ALL packets from the
// runner NICs to the capture VM's NIC via an internal
// load balancer (ILB) — the only supported collector endpoint.
//
// Architecture:
//
//   curl-runner NIC ──┐
//                     ├──[VNet TAP]──► ILB frontend ──► capture VM NIC
//   chrome-runner NIC ┘                (10.10.2.10)      (port 4789 VXLAN)
//
// The TAP encapsulates mirrored frames in VXLAN (UDP/4789)
// and delivers them to the ILB. The capture VM decapsulates
// and writes raw frames — tcpdump sees the inner Ethernet frame.
//
// Constraints:
//   • ILB must be Standard SKU, HA ports rule (proto=All, port=0)
//   • TAP destination must be an ILB frontend IP (not a VM IP directly)
//   • VNet TAP is applied per-NIC, not per-subnet — we apply it
//     after ACI container NICs are created each run (see run-tests.sh)
// ============================================================
param location          string
param env               string
param captureSubnetId   string
param captureNicId      string   // NIC of the capture VM

var ilbName    = 'ilb-tap-${env}'
var tapName    = 'tap-runners-${env}'
var frontendIp = '10.10.2.10'   // static IP in capture subnet, reserved for ILB

// ── Internal Load Balancer (TAP collector endpoint) ──────────
resource ilb 'Microsoft.Network/loadBalancers@2023-04-01' = {
  name:     ilbName
  location: location
  sku: { name: 'Standard' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'tap-frontend'
        properties: {
          privateIPAddress:          frontendIp
          privateIPAllocationMethod: 'Static'
          subnet: { id: captureSubnetId }
        }
      }
    ]
    backendAddressPools: [
      { name: 'capture-vm-pool' }
    ]
    // HA ports rule — mirrors ALL protocols/ports to the backend
    loadBalancingRules: [
      {
        name: 'ha-ports-tap'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations',
                           ilbName, 'tap-frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools',
                           ilbName, 'capture-vm-pool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes',
                           ilbName, 'tcp-probe')
          }
          protocol:             'All'   // HA ports
          frontendPort:         0       // 0 = all ports
          backendPort:          0
          enableFloatingIP:     false
          idleTimeoutInMinutes: 4
        }
      }
    ]
    probes: [
      {
        name: 'tcp-probe'
        properties: {
          protocol:          'Tcp'
          port:              4789       // VXLAN port on capture VM
          intervalInSeconds: 5
          numberOfProbes:    2
        }
      }
    ]
  }
}

// ── Associate capture VM NIC with ILB backend pool ───────────
// (capture VM NIC is passed in as a param — created in capture-vm.bicep)
resource nicBackendAssoc 'Microsoft.Network/networkInterfaces@2023-04-01' existing = {
  name: last(split(captureNicId, '/'))
}

// NOTE: NIC backendAddressPools association is done via a NIC update.
// This is expressed as a separate module call in main.bicep after
// both capture-vm and vnet-tap are deployed, to avoid circular deps.

// ── VNet TAP resource ─────────────────────────────────────────
// Applied to individual NICs — see dynamic application in run-tests.sh
// This resource defines the TAP configuration; attachment is per-NIC.
resource vnetTap 'Microsoft.Network/virtualNetworkTaps@2023-04-01' = {
  name:     tapName
  location: location
  properties: {
    destinationLoadBalancerFrontEndIPConfiguration: {
      id: '${ilb.id}/frontendIPConfigurations/tap-frontend'
    }
    destinationPort: 4789   // VXLAN — decapsulated by vxlan-decap.service on capture VM
  }
}

output tapId           string = vnetTap.id
output tapName         string = vnetTap.name
output ilbFrontendIp   string = frontendIp
output ilbId           string = ilb.id
