#!/bin/bash

# Script trace mode
if [ "${DEBUG_MODE}" == "true" ]; then
    set -o xtrace
fi

# If requested, perform a healthcheck and exit
if [[ ${1,,} == "healthcheck" ]]; then
    ps -q $(cat /var/run/krb5kdc.pid) | grep "krb5kdc" > /dev/null
    krb5kdc_status=$?
    ps -q $(cat /var/run/kadmind.pid) | grep "kadmin" > /dev/null
    kadmin_status=$?
    if [ $krb5kdc_status -ne 0 ] || [ $kadmin_status -ne 0 ]; then
        echo "Error: krb5kdc and/or kadmin service are no longer running. Healthcheck failed."
        exit 1
    fi
    exit 0
fi

echo "Starting Kerberos KDC/KADMIN container with LDAP"

if [ "$(ls -A /etc/pki/trust/anchors)" ]; then
    echo "SSL certificate trust found. Running update-ca-certificates"
    /usr/sbin/update-ca-certificates -v
fi



# usage: file_env VAR [DEFAULT]
# as example: file_env 'MYSQL_PASSWORD' 'zabbix'
#    (will allow for "$MYSQL_PASSWORD_FILE" to fill in the value of "$MYSQL_PASSWORD" from a file)
# unsets the VAR_FILE afterwards and just leaving VAR
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local defaultValue="${2:-}"

    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        echo "**** Both variables $var and $fileVar are set (but are exclusive)"
        exit 1
    fi

    local val="$defaultValue"

    if [ "${!var:-}" ]; then
        val="${!var}"
        echo "** Using ${var} variable from ENV"
    elif [ "${!fileVar:-}" ]; then
        if [ ! -f "${!fileVar}" ]; then
            echo "**** Secret file \"${!fileVar}\" is not found"
            exit 1
        fi
        val="$(< "${!fileVar}")"
        echo "** Using ${var} variable from secret file"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

ldap_create_person() {
    ldap_url=$1
    dn_prefix=$2
    cnsn=$3
    suffix=$4

    echo "  - Adding user $cnsn"
    /usr/bin/ldapadd -H $ldap_url -x -D "${DM_DN}" -w "${DM_PASS}" <<EOL 
dn: $dn_prefix,$suffix
objectClass: person
objectClass: top
sn: $cnsn
EOL
    status=$?
    if [ $status -ne 0 ] && [ $status -ne 68 ]; then 
        echo "Failed adding user $cnsn in $dn_prefix,$suffix"
        exit 1
    fi
}

ldap_change_password() {
    ldap_url=$1
    dn=$2
    new_pass=$3

    /usr/bin/ldappasswd -H $ldap_url -x -D "${DM_DN}" -w "${DM_PASS}" -s $new_pass $dn
    status=$?
    if [ $status -ne 0 ]; then
        echo "Failed changing password for $dn"
        exit 1
    fi
}

ldap_aci_allow_modify() {
    ldap_url=$1
    dn=$2
    rule_nickname=$3
    user_dn=$4

    /usr/bin/ldapmodify -H $ldap_url -x -D "${DM_DN}" -w "${DM_PASS}" <<EOL
dn: $dn
changetype: modify
add: aci
aci: (target="ldap:///$dn")(targetattr=*)
     (version 3.0; acl "$rule_nickname"; allow (all)
     userdn = "ldap:///$user_dn";)
EOL
    status=$?
    if [ $status -ne 0 ]; then 
        echo "Failed to modify directory permission!"
        exit 1
    fi
}

save_password_into_file() {
    dn=$1
    pass=$2
    file_path=$3

    /usr/lib/mit/sbin/kdb5_ldap_util stashsrvpw -f $file_path -w "$pass" "$dn" <<EOL
$pass
$pass

EOL
    if [ $? -ne 0 ]; then  
        echo "Failed to add password for $dn to $file_path!"
        exit 1
    fi
}

if [ ! -f /var/lib/kerberos/krb5kdc/ldap.creds ]; then
    echo "Kerberos server not configured"
    echo "Starting configuration"

    DESTROY_AND_RECREATE=${DESTROY_AND_RECREATE:-false}
    file_env MASTER_PASS
    REALM_NAME=${REALM_NAME:-EXAMPLE.NET}
    DIR_SUFFIX=${DIR_SUFFIX:-dc=example,dc=com}
    KDC_DN_PREFIX=${KDC_DN_PREFIX:-cn=krbkdc}
    file_env KDC_PASS
    ADMIN_DN_PREFIX=${ADMIN_DN_PREFIX:-cn=krbadm}
    file_env ADMIN_PASS
    CONTAINER_DN=${CONTAINER_DN:-cn=kdc},${DIR_SUFFIX}
    DM_DN=${DM_DN:-cn=Directory Manager}
    file_env DM_PASS

    ldap_url=ldaps://${LDAP_HOST}:${LDAP_PORT:-636}
    kdc_dn=${KDC_DN_PREFIX},${DIR_SUFFIX}
    admin_dn=${ADMIN_DN_PREFIX},${DIR_SUFFIX}

    echo " - Create kerberos users and give them a password in Directory Server $ldap_url"
    ldap_create_person $ldap_url "${KDC_DN_PREFIX}" "Kerberos KDC Connection" "${DIR_SUFFIX}"
    ldap_change_password $ldap_url "$kdc_dn" "${KDC_PASS}"
    ldap_create_person $ldap_url "${ADMIN_DN_PREFIX}" "Kerberos Administration Connection" "${DIR_SUFFIX}"
    ldap_change_password $ldap_url "$admin_dn" "${ADMIN_PASS}"

    echo " - Generating /var/lib/kerberos/krb5kdc/krb5.conf"
    cat > /var/lib/kerberos/krb5kdc/krb5.conf <<EOF
[libdefaults]
    # \"dns_canonicalize_hostname\" and \"rdns\" are better set to false for improved security.
    # If set to true, the canonicalization mechanism performed by Kerberos client may
    # allow service impersonification, the consequence is similar to conducting TLS certificate
    # verification without checking host name.
    # If left unspecified, the two parameters will have default value true, which is less secure.
    dns_canonicalize_hostname = false
    rdns = false
    default_realm = ${REALM_NAME}
    default_ccache_name = FILE:/tmp/krb5cc_%{uid}
[realms]
    ${REALM_NAME} = {
            kdc = localhost
            admin_server = localhost
    }
[domain_realm]
    .${REALM_NAME,,} = ${REALM_NAME}
    ${REALM_NAME,,} = ${REALM_NAME}
[logging]
    kdc = FILE:/var/log/krb5/krb5kdc.log
    admin_server = FILE:/var/log/krb5/kadmind.log
    default = FILE:/var/log/krb5libs.log
EOF

    echo " - Generating /var/lib/kerberos/krb5kdc/kdc.conf"
    cat > /var/lib/kerberos/krb5kdc/kdc.conf <<EOF
[kdcdefaults]
    kdc_ports = 750,88
[realms]
    ${REALM_NAME} = {
        database_module = contact_ldap
    }
[dbdefaults]
[dbmodules]
    contact_ldap = {
            db_library = kldap
            ldap_kdc_dn = "$kdc_dn"
            ldap_kadmind_dn = "$admin_dn"
            ldap_kerberos_container_dn = "${CONTAINER_DN}"
            ldap_service_password_file = /var/lib/kerberos/krb5kdc/ldap.creds
            ldap_servers = $ldap_url
    }
[logging]
    kdc = FILE:/var/log/krb5/krb5kdc.log
    admin_server = FILE:/var/log/krb5/kadmind.log
EOF

    pass_file_path=/var/lib/kerberos/krb5kdc/ldap.creds
    echo " - Generating KRBADM/KDC Passwords to $pass_file_path"
    save_password_into_file "$kdc_dn" "${KDC_PASS}" $pass_file_path
    save_password_into_file "$admin_dn" "${ADMIN_PASS}" $pass_file_path

    if [ ${DESTROY_AND_RECREATE} == "true" ]; then
        echo " - Destroying existing realm from Directory server"
        /usr/lib/mit/sbin/kdb5_ldap_util -H $ldap_url -D "${DM_DN}" -w "${DM_PASS}" destroy -f -r "${REALM_NAME}"
    fi
    echo " - Initialize Directory server for Kerberos operation"
    /usr/lib/mit/sbin/kdb5_ldap_util -H $ldap_url -D "${DM_DN}" -w "${DM_PASS}" create -r "${REALM_NAME}" -subtrees "${CONTAINER_DN}" -s -P "${MASTER_PASS}"
    status=$?
    if [ $status -ne 0 ]; then 
        echo "Kerberos initialisation failure!"
        exit 1
    fi

    echo " - Give kerberos rights to modify directory"
    ldap_aci_allow_modify $ldap_url "${CONTAINER_DN}" "kerberos-admin" "$admin_dn"
    ldap_aci_allow_modify $ldap_url "${CONTAINER_DN}" "kerberos-kdc" "$kdc_dn"
fi

echo "Symlink /var/lib/kerberos/krb5kdc/krb5.conf -> /etc/krb5.conf"
rm -f /etc/krb5.conf
ln -s /var/lib/kerberos/krb5kdc/krb5.conf /etc/krb5.conf

# Start Kerberos services
echo "Starting kadmin..."
/usr/lib/mit/sbin/kadmind -P /var/run/kadmind.pid 
echo "Starting krb5kdc..."
/usr/lib/mit/sbin/krb5kdc -P /var/run/krb5kdc.pid


# Show kdc logging as output. Tail will exit when receiving SIGTERM.
tail -f /var/log/krb5/krb5kdc.log &
tail_pid=$!
trap 'kill $tail_pid' TERM INT
wait $tail_pid

# At this point the container is shutting down, so we stop all
# services
echo "Shutting down krb5kdc..."
kill $(cat /var/run/krb5kdc.pid)
echo "Shutting down kadmin..."
kill $(cat /var/run/kadmind.pid)

# Make sure services are really shut down before we stop.
while true; do
    ps -xq $(cat /var/run/krb5kdc.pid) | grep "/usr/lib/mit/sbin/krb5kdc" > /dev/null
    krb5kdc_status=$?
    ps -xq $(cat /var/run/kadmind.pid) | grep "/usr/lib/mit/sbin/kadmind" > /dev/null
    kadmin_status=$?
    if [ $krb5kdc_status -ne 0 ] && [ $kadmin_status -ne 0 ]; then
        exit 0
    fi
    sleep 1
done