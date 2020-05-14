FROM opensuse/tumbleweed
MAINTAINER Robin Roevens <robin.roevens@disroot.org>

RUN zypper ref && \
    # Work around https://github.com/openSUSE/obs-build/issues/487 \
    zypper install -y openSUSE-release-appliance-docker && \
    zypper -n in krb5-client krb5-server krb5-plugin-kdb-ldap openldap2-client cyrus-sasl-gssapi && \
    zypper clean -a 

COPY [ "start.sh", "/usr/bin/" ]
RUN chmod a+x /usr/bin/start.sh

VOLUME [ "/var/lib/kerberos/krb5kdc" ]

EXPOSE 88 749

HEALTHCHECK CMD [ "/usr/bin/start.sh","healthcheck" ]

CMD [ "/usr/bin/start.sh" ]