#!/bin/sh

# shellcheck disable=1091
. mail-toaster.sh || exit

install_haproxy()
{
	tell_status "installing haproxy"
	stage_pkg_install haproxy || exit
}

configure_haproxy()
{
	tell_status "configuring haproxy"
	tee "$STAGE_MNT/usr/local/etc/haproxy.conf" <<EO_HAPROXY_CONF
global
    daemon
    maxconn     256  # Total Max Connections. This is dependent on ulimit
    nbproc      1
    ssl-default-bind-options no-sslv3 no-tls-tickets

defaults
    mode        http
    balance     roundrobin
    option      forwardfor   # set X-Forwarded-For
    timeout     connect 5s
    timeout     server 30s
    timeout     client 30s
#   timeout     client 86400s
    timeout     tunnel 1h

#listen stats *:9000
#    mode http
#    balance
#    stats uri /haproxy_stats
#    stats realm HAProxy\ Statistics
#    stats auth admin:password
#    stats admin if TRUE

frontend http-in
    bind *:80
    acl is_websocket hdr(Upgrade) -i WebSocket
    acl is_websocket hdr_beg(Host) -i ws
    use_backend socket_smtp    if  is_websocket
    redirect scheme https code 301 if !is_websocket !{ ssl_fc }

frontend https-in
    bind *:443 ssl crt /etc/ssl/private
    # ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128:AES256:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!3DES:!MD5:!PSK
    reqadd X-Forwarded-Proto:\ https
    default_backend www_webmail

    acl is_websocket hdr(Upgrade) -i WebSocket
    acl is_websocket hdr_beg(Host) -i ws

    acl munin        path_beg /munin
    acl nagios       path_beg /nagios
    acl watch        path_beg /watch
    acl haraka       path_beg /haraka
    acl qmailadmin   path_beg /qmailadmin
    acl qmailadmin   path_beg /cgi-bin/qmailadmin
    acl sqwebmail    path_beg /sqwebmail
    acl sqwebmail    path_beg /cgi-bin/sqwebmail
    acl isoqlog      path_beg /isoqlog
    acl rspamd       path_beg /rspamd

    use_backend socket_smtp    if  is_websocket
    use_backend www_monitor    if  munin
    use_backend www_monitor    if  nagios
    use_backend www_smtp       if  watch
    use_backend www_vpopmail   if  qmailadmin
    use_backend www_vpopmail   if  sqwebmail
    use_backend www_vpopmail   if  isoqlog
    use_backend www_smtp       if  haraka
    use_backend www_rspamd     if  rspamd

    default_backend www_webmail

backend www_vpopmail
    server vpopmail $(get_jail_ip vpopmail):80

backend www_smtp
    server smtp $(get_jail_ip haraka):80
    reqirep ^([^\ :]*)\ /haraka/(.*)    \1\ /\2

backend socket_smtp
    timeout queue 5s
    timeout server 86400s
    timeout connect 86400s
    server smtp $(get_jail_ip haraka):80

backend www_webmail
    server webmail $(get_jail_ip webmail):80

backend www_monitor
    server monitor $(get_jail_ip monitor):80

backend www_rspamd
    server monitor $(get_jail_ip rspamd):11334
    reqirep ^([^\ :]*)\ /rspamd/(.*)    \1\ /\2
EO_HAPROXY_CONF

	if ls /etc/ssl/private/*.pem; then
		tell_status "copying PEM files"
		cp /etc/ssl/private/*.pem "$STAGE_MNT/etc/ssl/private/"
	else
		tell_status "concatenating server key and crt to PEM"
		cat /etc/ssl/private/server.key /etc/ssl/certs/server.crt \
			> "$STAGE_MNT/etc/ssl/private/server.pem" || exit
	fi
}

start_haproxy()
{
	tell_status "starting haproxy"
	stage_sysrc haproxy_enable=YES
	stage_exec service haproxy start
}

test_haproxy()
{
	tell_status "testing haproxy"
	stage_exec sockstat -l -4 | grep 443 || exit
	echo "it worked"
}

base_snapshot_exists || exit
create_staged_fs haproxy
start_staged_jail
install_haproxy
configure_haproxy
start_haproxy
test_haproxy
promote_staged_jail haproxy
