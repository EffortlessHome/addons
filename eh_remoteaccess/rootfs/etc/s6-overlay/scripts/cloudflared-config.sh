#!/command/with-contenv bashio
# shellcheck disable=SC2207
# ==============================================================================
# Home Assistant Add-on: Cloudflared
#
# Configures the Cloudflare Tunnel and creates the needed DNS entry under the
# given hostname(s)
# ==============================================================================

# ------------------------------------------------------------------------------
# Checks if the config is valid
# ------------------------------------------------------------------------------
checkConfig() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Checking add-on config..."

    local validHostnameRegex="^(([a-z0-9äöüß]|[a-z0-9äöüß][a-z0-9äöüß\-]*[a-z0-9äöüß])\.)*([a-z0-9]|[a-z0-9][a-z0-9\-]*[a-z0-9])$"

    # Check for minimum configuration options
    if bashio::config.is_empty 'eh_email_address'  &&
        bashio::config.is_empty 'eh_system_id' ;
    then
        bashio::exit.nok "Cannot run without email address and system id. Please set these add-on options."
    fi
}

# ------------------------------------------------------------------------------
# Checks if Cloudflare services are reachable
# ------------------------------------------------------------------------------
checkConnectivity() {
    local pass_test=true

    # Check for region1 TCP
    bashio::log.debug "Checking region1.v2.argotunnel.com TCP port 7844"
    if ! nc -z -w 1 region1.v2.argotunnel.com 7844 &> /dev/null ; then
        bashio::log.warning "region1.v2.argotunnel.com TCP port 7844 not reachable"
        pass_test=false
    fi

    # Check for region1 UDP
    bashio::log.debug "Checking region1.v2.argotunnel.com UDP port 7844"
    if ! nc -z -u -w 1 region1.v2.argotunnel.com 7844 &> /dev/null ; then
        bashio::log.warning "region1.v2.argotunnel.com UDP port 7844 not reachable"
        pass_test=false
    fi

    # Check for region2 TCP
    bashio::log.debug "Checking region2.v2.argotunnel.com TCP port 7844"
    if ! nc -z -w 1 region2.v2.argotunnel.com 7844 &> /dev/null ; then
        bashio::log.warning "region2.v2.argotunnel.com TCP port 7844 not reachable"
        pass_test=false
    fi

    # Check for region2 UDP
    bashio::log.debug "Checking region2.v2.argotunnel.com UDP port 7844"
    if ! nc -z -u -w 1 region2.v2.argotunnel.com 7844 &> /dev/null ; then
        bashio::log.warning "region2.v2.argotunnel.com UDP port 7844 not reachable"
        pass_test=false
    fi

    # Check for API TCP
    bashio::log.debug "Checking api.cloudflare.com TCP port 443"
    if ! nc -z -w 1 api.cloudflare.com 443 &> /dev/null ; then
        bashio::log.warning "api.cloudflare.com TCP port 443 not reachable"
        pass_test=false
    fi

    if bashio::var.false ${pass_test} ; then
        bashio::log.warning "Some necessary services may not be reachable from your host."
        bashio::log.warning "Please review lines above and check your firewall/router settings."
    fi

}

# ------------------------------------------------------------------------------
# Check if Cloudflared certificate (authorization) is available
# ------------------------------------------------------------------------------
hasCertificate() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Checking for existing certificate..."
    if bashio::fs.file_exists "${data_path}/cert.pem" ; then
        bashio::log.info "Existing certificate found"
        return "${__BASHIO_EXIT_OK}"
    fi

    bashio::log.notice "No certificate found"
    return "${__BASHIO_EXIT_NOK}"
}

# ------------------------------------------------------------------------------
# Create cloudflare certificate
# ------------------------------------------------------------------------------
createCertificate() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Creating new certificate..."
    bashio::log.notice
    bashio::log.notice "Please follow the Cloudflare Auth-Steps:"
    bashio::log.notice
    cloudflared tunnel login

    bashio::log.info "Authentication successful, moving auth file to the '${data_path}' folder"

    mv /root/.cloudflared/cert.pem "${data_path}/cert.pem" || bashio::exit.nok "Failed to move auth file"

    hasCertificate || bashio::exit.nok "Failed to create certificate"
}

# ------------------------------------------------------------------------------
# Check if Cloudflare Tunnel is existing
# ------------------------------------------------------------------------------
hasTunnel() {
    bashio::log.trace "${FUNCNAME[0]}:"
    bashio::log.info "Checking for existing tunnel..."

    # Check if tunnel file(s) exist
    if ! bashio::fs.file_exists "${data_path}/tunnel.json" ; then
        bashio::log.notice "No tunnel file found"
        return "${__BASHIO_EXIT_NOK}"
    fi

    # Get tunnel UUID from JSON
    tunnel_uuid="$(bashio::jq "${data_path}/tunnel.json" ".TunnelID")"

    bashio::log.info "Existing tunnel with ID ${tunnel_uuid} found"

    # Get tunnel name from Cloudflare API by tunnel id and chek if it matches config value
    bashio::log.info "Checking if existing tunnel matches name given in config"
    local existing_tunnel_name
    existing_tunnel_name=$(cloudflared --origincert="${data_path}/cert.pem" tunnel \
        list --output="json" --id="${tunnel_uuid}" | jq -er '.[].name')
    bashio::log.debug "Existing Cloudflare Tunnel name: $existing_tunnel_name"
    if [[ $tunnel_name != "$existing_tunnel_name" ]]; then
        bashio::log.error "Existing Cloudflare Tunnel name does not match add-on config."
        bashio::log.error "---------------------------------------"
        bashio::log.error "Add-on Configuration tunnel name: ${tunnel_name}"
        bashio::log.error "Tunnel credentials file tunnel name: ${existing_tunnel_name}"
        bashio::log.error "---------------------------------------"
        bashio::log.error "Align add-on configuration to match existing tunnel credential file"
        bashio::log.error "or re-install the add-on."
        bashio::exit.nok
    fi
    bashio::log.info "Existing Cloudflare Tunnel name matches config, proceeding with existing tunnel file"

    return "${__BASHIO_EXIT_OK}"
}

# ------------------------------------------------------------------------------
# Create Cloudflare Tunnel with name from HA-Add-on-Config
# ------------------------------------------------------------------------------
createTunnel() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Creating new tunnel..."
    cloudflared --origincert="${data_path}/cert.pem" --cred-file="${data_path}/tunnel.json" tunnel --loglevel "${CLOUDFLARED_LOG}" create "${tunnel_name}" \
    || bashio::exit.nok "Failed to create tunnel.
    Please check the Cloudflare Zero Trust Dashboard for an existing tunnel with the name ${tunnel_name} and delete it:
    Visit https://one.dash.cloudflare.com, then click on Access / Tunnels"

    bashio::log.debug "Created new tunnel: $(cat "${data_path}"/tunnel.json)"

    hasTunnel || bashio::exit.nok "Failed to create tunnel"
}

# ------------------------------------------------------------------------------
# Create Cloudflare config with variables from HA-Add-on-Config
# ------------------------------------------------------------------------------
createConfig() {
    local ha_service_protocol
    local config
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Creating config file..."

    # Add tunnel information
    config=$(bashio::jq "{\"tunnel\":\"${tunnel_uuid}\"}" ".")
    config=$(bashio::jq "${config}" ".\"credentials-file\" += \"${data_path}/tunnel.json\"")

    bashio::log.debug "Checking if SSL is used..."
    if bashio::var.true "$(bashio::core.ssl)" ; then
        ha_service_protocol="https"
    else
        ha_service_protocol="http"
    fi
    bashio::log.debug "ha_service_protocol: ${ha_service_protocol}"

    if bashio::var.is_empty "${ha_service_protocol}" ; then
        bashio::exit.nok "Error checking if SSL is enabled"
    fi

    # Add Service for Home Assistant if 'external_hostname' is set
    if bashio::config.has_value 'external_hostname' ; then
        config=$(bashio::jq "${config}" ".\"ingress\" += [{\"hostname\": \"${external_hostname}\", \"service\": \"${ha_service_protocol}://homeassistant:$(bashio::core.port)\"}]")
    fi


    # Finalize config without NPM support and catch all service, sending all other requests to HTTP:404
    config=$(bashio::jq "${config}" ".\"ingress\" += [{\"service\": \"http_status:404\"}]")
 

    # Deactivate TLS verification for all services
    config=$(bashio::jq "${config}" ".ingress[].originRequest += {\"noTLSVerify\": true}")

    # Write content of config variable to config file for cloudflared
    bashio::jq "${config}" "." > "${default_config}"

    # Validate config using cloudflared
    bashio::log.info "Validating config file..."
    bashio::log.debug "Validating created config file: $(bashio::jq "${default_config}" ".")"
    cloudflared tunnel --config="${default_config}" --loglevel "${CLOUDFLARED_LOG}" ingress validate \
    || bashio::exit.nok "Validation of Config failed, please check the logs above."

    bashio::log.debug "Sucessfully created config file: $(bashio::jq "${default_config}" ".")"
}

# ------------------------------------------------------------------------------
# Create cloudflare DNS entry for external hostname and additional hosts
# ------------------------------------------------------------------------------
createDNS() {
    bashio::log.trace "${FUNCNAME[0]}"

    # Create DNS entry for external hostname of Home Assistant if 'external_hostname' is set
    if bashio::config.has_value 'external_hostname' ; then
        bashio::log.info "Creating DNS entry ${external_hostname}..."
        cloudflared --origincert="${data_path}/cert.pem" tunnel --loglevel "${CLOUDFLARED_LOG}" route dns -f "${tunnel_uuid}" "${external_hostname}" \
        || bashio::exit.nok "Failed to create DNS entry ${external_hostname}."
    fi

}

# ------------------------------------------------------------------------------
# Set Cloudflared log level
# ------------------------------------------------------------------------------
setCloudflaredLogLevel() {

    # Set cloudflared log to "info" as default
    CLOUDFLARED_LOG="info"

    # Check if user wishes to change log severity
    if bashio::config.has_value 'run_parameters' ; then
        bashio::log.trace "bashio::config.has_value 'run_parameters'"
        for run_parameter in $(bashio::config 'run_parameters'); do
            bashio::log.trace "Checking run_parameter: ${run_parameter}"
            if [[ $run_parameter == --loglevel=* ]]; then
                CLOUDFLARED_LOG=${run_parameter#*=}
                bashio::log.trace "Setting CLOUDFLARED_LOG to: ${run_parameter#*=}"
            fi
        done
    fi

    bashio::log.debug "Cloudflared log level set to \"${CLOUDFLARED_LOG}\""

}

effortlesshomelogic() {
    # Log that the add-on is starting
    bashio::log.trace "Starting the EH integration process"

    # Get the email address and system ID from the add-on configuration
    EH_EMAIL_ADDRESS=$(bashio::config 'eh_email_address')
    EH_SYSTEM_ID=$(bashio::config 'eh_system_id')

    # Construct the URL for the API call
    API_URL="https://ehsysteminitialize.effortlesshome.co/getremoteaccessinfo/${EH_EMAIL_ADDRESS}/${EH_SYSTEM_ID}"

    # Log the URL for debugging (optional)
    bashio::log.trace "Calling EH API at: ${API_URL}"

    # Make the API call and store the response
    RESPONSE=$(curl -s -X GET "${API_URL}")

    # Check if the response contains valid data
    if bashio::var.has_value "${RESPONSE}"; then
        bashio::log.info "EH API call successful, response: ${RESPONSE}"

        # Parse the JSON response using jq to extract Token and URL
        TOKEN=$(echo "${RESPONSE}" | jq -r '.Token')
        REMOTE_URL=$(echo "${RESPONSE}" | jq -r '.URL')

        # Check if values were extracted successfully
        if bashio::var.has_value "${TOKEN}" && bashio::var.has_value "${REMOTE_URL}"; then
            bashio::log.info "Token: ${TOKEN}"
            bashio::log.info "Remote Access URL: ${REMOTE_URL}"
        else
            bashio::log.error "Failed to extract Token or URL from the response."
            exit 1  # Exit with error if values could not be extracted
        fi
    else
        bashio::log.error "EH API call failed or returned an empty response."
        #exit 1  # Exit with error if the API call fails
    fi

    # Continue with the rest of the add-on logic if necessary

}

# ==============================================================================
# RUN LOGIC
# ------------------------------------------------------------------------------
declare default_config=/tmp/config.json
external_hostname=""
tunnel_name="homeassistant"
tunnel_uuid=""
data_path="/data"
TOKEN=""

main() {
    bashio::log.trace "${FUNCNAME[0]}"

    setCloudflaredLogLevel

    # Run connectivity checks if debug mode activated
    if bashio::debug ; then
        bashio::log.debug "Checking connectivity to Cloudflare"
        checkConnectivity
    fi

    bashio::log.trace "Starting the EH integration process"

    # Get the email address and system ID from the add-on configuration
    EH_EMAIL_ADDRESS=$(bashio::config 'eh_email_address')
    EH_SYSTEM_ID=$(bashio::config 'eh_system_id')

    # Construct the URL for the API call
    API_URL="https://ehsysteminitialize.effortlesshome.co/getremoteaccessinfo/${EH_EMAIL_ADDRESS}/${EH_SYSTEM_ID}"

    # Log the URL for debugging (optional)
    bashio::log.trace "Calling EH API at: ${API_URL}"

    # Make the API call and store the response
    RESPONSE=$(curl -s -X GET "${API_URL}")

    # Check if the response contains valid data
    if bashio::var.has_value "${RESPONSE}"; then
        bashio::log.info "EH API call successful, response: ${RESPONSE}"

        # Parse the JSON response using jq to extract Token and URL
        TOKEN=$(echo "${RESPONSE}" | jq -r '.Token')
        REMOTE_URL=$(echo "${RESPONSE}" | jq -r '.URL')

        # Check if values were extracted successfully
        if bashio::var.has_value "${TOKEN}" && bashio::var.has_value "${REMOTE_URL}"; then
            bashio::log.info "Token: ${TOKEN}"
            bashio::log.info "Remote Access URL: ${REMOTE_URL}"

            bashio::log.info "Using Cloudflare Remote Management Tunnel"
            bashio::exit.ok
        else
            bashio::log.error "Failed to extract Token or URL from the response."
            exit 1  # Exit with error if values could not be extracted
        fi
    else
        bashio::log.error "EH API call failed or returned an empty response."
        exit 1  # Exit with error if the API call fails
    fi


    checkConfig

    if bashio::config.has_value 'tunnel_name' ; then
        tunnel_name="$(bashio::config 'tunnel_name')"
    fi

    external_hostname="$(bashio::config 'external_hostname')"

    if ! hasCertificate ; then
        createCertificate
    fi

    if ! hasTunnel ; then
        createTunnel
    fi

    createConfig

    createDNS

    

    bashio::log.info "Finished setting up the Cloudflare Tunnel"
}
main "$@"
