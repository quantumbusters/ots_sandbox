// ============================================================
// capture-vm.bicep
// Ubuntu 22.04 B2s VM — packet capture, compress, upload, notify
// Deployed once; started/stopped per run via az cli
// ============================================================
param location    string
param env         string
param vnetId      string
param adminUser   string = 'captureuser'

@secure()
param adminSshKey string    // paste your public key

param storageAccountName string
param offSiteWebhookUrl  string
param runnerSubnetPrefix string = '10.10.1.0/24'

var vmName     = 'vm-capture-${env}'
var nicName    = 'nic-capture-${env}'
var subnetName = 'snet-capture'
var nsgName    = 'nsg-capture-${env}'

// ── Capture subnet (separate from ACI runner subnet) ─────────
resource captureSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-04-01' = {
  name: '${split(vnetId, '/')[8]}/${subnetName}'
  properties: {
    addressPrefixes: [
      '10.10.2.0/24'
      'ace:cab:deca:deeb::/64'
    ]
  }
}

// ── NSG: allow SSH from your IP only, deny all else inbound ──
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'   // tighten to your IP in prod
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ── Public IP (needed for SSH + outbound to blob/webhook) ────
resource pip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: 'pip-capture-${env}'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// ── NIC in capture subnet ─────────────────────────────────────
resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: nicName
  location: location
  properties: {
    enableIPForwarding: false
    networkSecurityGroup: { id: nsg.id }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.10.2.4'    // fixed IP — referenced in tcpdump filters
          subnet: { id: captureSubnet.id }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

// ── VM ────────────────────────────────────────────────────────
resource vm 'Microsoft.Compute/virtualMachines@2023-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_B2s' }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer:     '0001-com-ubuntu-server-jammy'
        sku:       '22_04-lts-gen2'
        version:   'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        diskSizeGB: 64          // capture files are temp; 64GB is sufficient
        deleteOption: 'Delete'  // disk removed when VM deleted
      }
    }
    osProfile: {
      computerName:  vmName
      adminUsername: adminUser
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path:    '/home/${adminUser}/.ssh/authorized_keys'
              keyData: adminSshKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

// ── cloud-init: install tools, write capture scripts ─────────
resource vmExt 'Microsoft.Compute/virtualMachines/extensions@2023-07-01' = {
  parent: vm
  name: 'customScript'
  location: location
  properties: {
    publisher:               'Microsoft.Azure.Extensions'
    type:                    'CustomScript'
    typeHandlerVersion:      '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      script: base64('''
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq tcpdump tshark gzip jq curl azure-cli
# Allow tcpdump without sudo for captureuser
setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump
# Put capture scripts in place (populated by run-tests.sh via SCP)
mkdir -p /opt/capture
echo "Bootstrap complete" > /opt/capture/ready
''')
    }
    protectedSettings: {}
  }
}

output captureVmId        string = vm.id
output captureVmPublicIp  string = pip.properties.ipAddress
output captureVmPrivateIp string = '10.10.2.4'
output captureSubnetId    string = captureSubnet.id
