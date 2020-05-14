# Kerberos KDC/KADMIN container with LDAP
This container runs a krb5kdc and a kadmind instance in an openSUSE Tumbleweed environment.

It will retain kerberos configuration, keytabs etc using a seperate 
volume for `/var/lib/kerberos/krb5kdc`.

It will use an external SSL LDAP server.

## Bootstrap container
If no LDAP admin/kdc credentials are found on the `/var/lib/kerberos/krb5kdc` volume,
the container will assume a first run and initiate a bootstrap procedure to set up
the Kerberos configuration both localy as remotely on the LDAP server.
This will require you to set all necessary [environment variables](#environment-variables).

## Starting container
Start the container as follows when it is already initialized:
```bash
podman run -v krb5kdb_data:/var/lib/kerberos/krb5kdc \
    -p 88:88 -p 749:749
    --healthcheck-command '/usr/bin/start.sh healthcheck' \
    --name some-krb5kdc sicho/kerberos:latest
```
Where `some-krb5kdc` is the name you want to assign to your container. 
***Tip:** add `-v /path/to/some-CA.pem:/etc/pki/trust/anchors/some-CA.pem` to add a custom 
CA certificate to the container if this is required to trust the certificate of the LDAP server.

## Auto starting container
Using podman, you can generate a systemd service-file to autostart the container on boot:
```bash
podman generate systemd --name some-krb5kdc > /etc/systemd/system/container-some-krb5kdc.service
systemctl daemon-reload
systemctl enable container-some-krb5kdc.service
```
If you are running your directory server also on this host, make sure kerberos is started after
the directory server is started. For example:
```bash
systemctl edit container-some-krb5kdc.service
```
```ini
[Unit]
After=container-some-dirsrv.service
```
## Container shell access
You can gain shell access using:
```bash
podman exec -ti some-krb5kdc /bin/bash
```

## Environment variables
### `LDAP_HOST`
FQDN Hostname of the LDAP server. **Required**
### `LDAP_PORT`
Port where the Secure LDAP server (ldaps://) is listening on. Defaults to `636`

### Bootstrap variables
When you first start the `kerberos` image, it will configure Kerberos and initialize the LDAP server
for use with Kerberos using the environment variables described here. All configuration is saved on
the volume `/var/lib/kerberos/krb5kdc` so if this volume is persistent, bootstrap won't be triggered
anymore and you no longer have to pass these variables to the `podman run` command anymore as they
are then no longer used.

#### `REALM_NAME`
This variable sets the realm name of the Kerberos domain you want to host. Defaults to `EXAMPLE.COM`
#### `DIR_SUFFIX`
Directory suffix. Defaults to `dc=example,dc=com`
#### `DM_DN`
Directory Manager account to use for initialization of LDAP. Don't include the directory suffix.
Defaults to 'cn=Directory Manager'
#### `DM_PASS`
Directory Manager password. Required for bootstrap.
#### `MASTER_PASS`
Kerberos database master password. Required for bootstrap
#### `KDC_DN_PREFIX`
KDC account to create. Don't include the directory suffix. Defaults to `cn=krbkdc`
#### `KDC_PASS`
KDC account password. Required for bootstrap.
#### `ADMIN_DN_PREFIX`
Admin account to create. Don't include the directory suffix. Defaults to `cn=krbadm`
#### `ADMIN_PASS`
Admin account password. Required for bootstrap.
#### `CONTAINER_DN`
KDC container DN. Don't include the directory suffix. Defaults to `cn=kdc`
#### `DESTROY_AND_RECREATE`
When set to `true`, the bootstrap script will try to first remove the Kerberos realm
configuration from the LDAP server before adding it. Use this if the realm was already 
initialized before but you have lost or want to re-initialize the data volume.

## Volumes
### `/var/lib/kerberos/krb5kdc`
Volume containing all Kerberos configuration and data

## Exposed Ports
### `Port 88`
The KDC daemon listens here
### `Port 749`
The Kadmin server daemon listens here