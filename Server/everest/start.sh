#!/bin/sh
# SPDX-FileCopyrightText: 2025 Contributors to the CitrineOS Project
#
# SPDX-License-Identifier: Apache-2.0

# Install sqlite3 for database modifications
if [ "$OCPP_VERSION" = "two" ] || [ "$OCPP_VERSION" = "one" ]; then
    apt-get update && apt-get install -y sqlite3
fi

/entrypoint.sh
http-server /tmp/everest_ocpp_logs -p 8888 &

if [ "$OCPP_VERSION" = "one" ]; then
    chmod +x /ext/build/run-scripts/run-sil-ocpp.sh
    sed -i "0,/127.0.0.1:8180\/steve\/websocket\/CentralSystemService\// s|127.0.0.1:8180/steve/websocket/CentralSystemService/|${EVEREST_TARGET_URL}|" /ext/dist/share/everest/modules/OCPP/config-docker.json
    /ext/build/run-scripts/run-sil-ocpp.sh
else
    rm -f /ext/dist/share/everest/modules/OCPP201/component_config/custom/EVSE_2.json
    rm -f /ext/dist/share/everest/modules/OCPP201/component_config/custom/Connector_2_1.json
    
    # Enable wildcard certificates for Azure Container Apps by modifying the standardized InternalCtrlr.json
    # Change VerifyCsmsAllowWildcards default from false to true and add "value": true to attributes
    INTERNAL_CTRLR_JSON=/ext/dist/share/everest/modules/OCPP201/component_config/standardized/InternalCtrlr.json
    
    # Use sed to modify the JSON file in place:
    # 1. Change "default": false to "default": true for VerifyCsmsAllowWildcards
    # 2. Add "value": true after "mutability": "ReadWrite" in the VerifyCsmsAllowWildcards section
    sed -i '/"VerifyCsmsAllowWildcards"/,/}$/ {
        s/"default": false/"default": true/
        s/"mutability": "ReadWrite"/"mutability": "ReadWrite",\n                "value": true/
    }' "$INTERNAL_CTRLR_JSON"
    
    echo "=== Modified standardized InternalCtrlr.json with VerifyCsmsAllowWildcards=true ==="
    
    # Configure OCPP URL and security profile AFTER entrypoint.sh initializes the database
    # Use securityProfile 2 for wss:// URLs (TLS), profile 1 for ws:// (basic auth)
    if echo "$EVEREST_TARGET_URL" | grep -q "^wss://"; then
        SECURITY_PROFILE=2
    else
        SECURITY_PROFILE=1
    fi
    # Database updates for NetworkConnectionProfiles (this may be overwritten by module init)
    sqlite3 /ext/dist/share/everest/modules/OCPP201/device_model_storage.db \
            "UPDATE VARIABLE_ATTRIBUTE \
            SET value = '[{\"configurationSlot\": 1, \"connectionData\": {\"messageTimeout\": 30, \"ocppCsmsUrl\": \"$EVEREST_TARGET_URL\", \"ocppInterface\": \"Wired0\", \"ocppTransport\": \"JSON\", \"ocppVersion\": \"OCPP20\", \"securityProfile\": $SECURITY_PROFILE}},{\"configurationSlot\": 2, \"connectionData\": {\"messageTimeout\": 30, \"ocppCsmsUrl\": \"$EVEREST_TARGET_URL\", \"ocppInterface\": \"Wired0\", \"ocppTransport\": \"JSON\", \"ocppVersion\": \"OCPP20\", \"securityProfile\": $SECURITY_PROFILE}}]' \
            WHERE \
            variable_Id IN ( \
            SELECT id FROM VARIABLE \
            WHERE name = 'NetworkConnectionProfiles' \
            );"
    
    chmod +x /ext/build/run-scripts/run-sil-ocpp201-pnc.sh
    /ext/build/run-scripts/run-sil-ocpp201-pnc.sh
fi