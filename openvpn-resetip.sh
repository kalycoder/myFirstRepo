#!/bin/bash

# Log file path
LOG_FILE="/var/log/openvpn-ip-update.log"

# Path to the OpenVPN server configuration file
OPENVPN_CONF="/etc/openvpn/server/server.conf"

# Path to the OpenVPN client common file
CLIENT_COMMON_TXT="/etc/openvpn/server/client-common.txt"

# Fetch the public IP address
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)
if [ $? -ne 0 ]; then
    echo "$(date) - Failed to fetch public IP address" >> $LOG_FILE
    exit 1
fi

# Log the detected public IP
echo "$(date) - Detected Public IP: $PUBLIC_IP" >> $LOG_FILE

# Extract the current IP from the OpenVPN server configuration file
CURRENT_IP=$(grep "^local " $OPENVPN_CONF | cut -d ' ' -f 2)

# Log the current IP in the config
echo "$(date) - Current IP in Config: $CURRENT_IP" >> $LOG_FILE

# Check if the IP has changed
if [ "$PUBLIC_IP" != "$CURRENT_IP" ]; then
    # Update the server configuration file with the new IP
    sed -i "s/local $CURRENT_IP/local $PUBLIC_IP/" $OPENVPN_CONF
    echo "$(date) - IP updated from $CURRENT_IP to $PUBLIC_IP in server.conf" >> $LOG_FILE

    # Debugging: Log current remote line
    echo "$(date) - Current remote line in client-common.txt: $(grep 'remote ' $CLIENT_COMMON_TXT)" >> $LOG_FILE

    # Update the client common file with the new IP
    sed -i "s/remote [0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ 1194/remote $PUBLIC_IP 1194/" $CLIENT_COMMON_TXT
    echo "$(date) - Attempted to update IP in client-common.txt" >> $LOG_FILE

    # Debugging: Log new remote line
    echo "$(date) - Updated remote line in client-common.txt: $(grep 'remote ' $CLIENT_COMMON_TXT)" >> $LOG_FILE

    # Restart OpenVPN to apply changes
    systemctl restart openvpn@server
    if [ $? -ne 0 ]; then
        echo "$(date) - Failed to restart OpenVPN service" >> $LOG_FILE
        exit 1
    fi
    echo "$(date) - OpenVPN service restarted" >> $LOG_FILE
else
    echo "$(date) - No change in IP. No update required." >> $LOG_FILE
fi
