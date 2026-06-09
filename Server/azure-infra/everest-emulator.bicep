// EVerest OCPP 2.0.1 Charger Emulator on Azure Container Instances
// This deploys a multi-container group with mqtt-server, manager, and nodered

@description('Environment name (dev, staging, prod)')
param environmentName string

@description('Location for resources')
param location string = resourceGroup().location

@description('EVerest image tag')
param everestImageTag string = '0.0.23'

@description('CitrineOS WebSocket URL for OCPP connection')
param citrineosCsmsUrl string

@description('Container registry for custom manager image (optional)')
param customRegistryServer string = ''

@description('Container registry username')
param customRegistryUsername string = ''

@secure()
@description('Container registry password')
param customRegistryPassword string = ''

var containerGroupName = 'aci-${environmentName}-everest-emulator'

// Image references
var mqttServerImage = 'ghcr.io/everest/everest-demo/mqtt-server:${everestImageTag}'
var managerImage = 'ghcr.io/everest/everest-demo/manager:${everestImageTag}'
var noderedImage = 'ghcr.io/everest/everest-demo/nodered:${everestImageTag}'

resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  properties: {
    osType: 'Linux'
    restartPolicy: 'OnFailure'
    
    // Image registry credentials (if using custom registry)
    imageRegistryCredentials: !empty(customRegistryServer) ? [
      {
        server: customRegistryServer
        username: customRegistryUsername
        password: customRegistryPassword
      }
    ] : []
    
    containers: [
      // MQTT Server - internal communication
      {
        name: 'mqtt-server'
        properties: {
          image: mqttServerImage
          resources: {
            requests: {
              cpu: json('0.25')
              memoryInGB: json('0.3')
            }
          }
          ports: [
            {
              port: 1883
              protocol: 'TCP'
            }
          ]
        }
      }
      
      // EVerest Manager - OCPP client
      {
        name: 'manager'
        properties: {
          image: managerImage
          resources: {
            requests: {
              cpu: json('0.5')
              memoryInGB: json('1')
            }
          }
          ports: [
            {
              port: 8888
              protocol: 'TCP'
            }
          ]
          environmentVariables: [
            {
              name: 'MQTT_SERVER_ADDRESS'
              value: 'localhost'  // All containers share localhost in ACI
            }
            {
              name: 'EVEREST_TARGET_URL'
              value: citrineosCsmsUrl
            }
            {
              name: 'OCPP_VERSION'
              value: 'two'
            }
          ]
          // Note: The default entrypoint won't work with our custom start.sh
          // We'll need a custom image or init container approach for production
          command: [
            '/bin/sh'
            '-c'
            '''
            set -ex
            
            apt-get update && apt-get install -y sqlite3 curl
            
            # Wait for MQTT server
            sleep 5
            
            # Initialize database by running entrypoint
            /entrypoint.sh
            
            # Start log server in background
            http-server /tmp/everest_ocpp_logs -p 8888 &
            
            # Remove second EVSE (single connector mode)
            rm -f /ext/dist/share/everest/modules/OCPP201/component_config/custom/EVSE_2.json
            rm -f /ext/dist/share/everest/modules/OCPP201/component_config/custom/Connector_2_1.json
            
            # Enable wildcard certificates for Azure Container Apps
            INTERNAL_CTRLR_JSON=/ext/dist/share/everest/modules/OCPP201/component_config/standardized/InternalCtrlr.json
            sed -i '/"VerifyCsmsAllowWildcards"/,/}$/ {
                s/"default": false/"default": true/
                s/"mutability": "ReadWrite"/"mutability": "ReadWrite",\n                "value": true/
            }' "$INTERNAL_CTRLR_JSON"
            
            # Configure OCPP URL and security profile
            if echo "$EVEREST_TARGET_URL" | grep -q "^wss://"; then
                SECURITY_PROFILE=2
            else
                SECURITY_PROFILE=1
            fi
            
            # Update network connection profiles
            sqlite3 /ext/dist/share/everest/modules/OCPP201/device_model_storage.db \
                "UPDATE VARIABLE_ATTRIBUTE \
                SET value = '[{\"configurationSlot\": 1, \"connectionData\": {\"messageTimeout\": 30, \"ocppCsmsUrl\": \"$EVEREST_TARGET_URL\", \"ocppInterface\": \"Wired0\", \"ocppTransport\": \"JSON\", \"ocppVersion\": \"OCPP20\", \"securityProfile\": $SECURITY_PROFILE}},{\"configurationSlot\": 2, \"connectionData\": {\"messageTimeout\": 30, \"ocppCsmsUrl\": \"$EVEREST_TARGET_URL\", \"ocppInterface\": \"Wired0\", \"ocppTransport\": \"JSON\", \"ocppVersion\": \"OCPP20\", \"securityProfile\": $SECURITY_PROFILE}}]' \
                WHERE variable_Id IN (SELECT id FROM VARIABLE WHERE name = 'NetworkConnectionProfiles');"
            
            # Start EVerest charger (this is the actual charger process)
            chmod +x /ext/build/run-scripts/run-sil-ocpp201-pnc.sh
            /ext/build/run-scripts/run-sil-ocpp201-pnc.sh
            '''
          ]
        }
      }
      
      // Node-RED UI - charger control interface
      {
        name: 'nodered'
        properties: {
          image: noderedImage
          resources: {
            requests: {
              cpu: json('0.25')
              memoryInGB: json('0.3')
            }
          }
          ports: [
            {
              port: 1880
              protocol: 'TCP'
            }
          ]
          environmentVariables: [
            {
              name: 'MQTT_SERVER_ADDRESS'
              value: 'localhost'
            }
            {
              name: 'FLOWS'
              value: '/config/config-sil-two-evse-flow.json'
            }
          ]
          // Patch MQTT broker hostname in flows before starting Node-RED.
          // The default image flows reference 'mqtt-server' which is the Docker Compose
          // service name. In ACI, all containers share localhost.
          command: [
            '/bin/sh'
            '-c'
            '''
            # Patch MQTT broker hostname from docker-compose service name to localhost
            sed -i 's/"broker":"mqtt-server"/"broker":"localhost"/g' /config/config-sil-two-evse-flow.json
            sed -i 's/"broker": "mqtt-server"/"broker": "localhost"/g' /config/config-sil-two-evse-flow.json
            
            # Start Node-RED with the patched flows
            exec node-red --userDir /data --flowFile /config/config-sil-two-evse-flow.json
            '''
          ]
        }
      }
    ]
    
    // Expose Node-RED UI and log server
    ipAddress: {
      type: 'Public'
      dnsNameLabel: '${containerGroupName}'
      ports: [
        {
          port: 1880
          protocol: 'TCP'
        }
        {
          port: 8888
          protocol: 'TCP'
        }
      ]
    }
  }
}

// Outputs
output containerGroupName string = containerGroup.name
output containerGroupFqdn string = containerGroup.properties.ipAddress.fqdn
output nodeRedUrl string = 'http://${containerGroup.properties.ipAddress.fqdn}:1880/ui'
output logsUrl string = 'http://${containerGroup.properties.ipAddress.fqdn}:8888'
