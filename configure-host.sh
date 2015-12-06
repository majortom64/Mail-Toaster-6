#!/bin/sh

. mail-toaster.sh || exit

export SAFE_NAME=`safe_jailname $BASE_NAME`

update_host_ntpd()
{
    tell_status "enabling NTPd"
    sysrc -f /etc/rc.conf ntpd_enable=YES || exit
    sysrc -f /etc/rc.conf ntpd_sync_on_start=YES
    /etc/rc.d/ntpd restart
}

update_syslogd()
{
    tell_status "turn off syslog network listener"
    sysrc -f /etc/rc.conf syslogd_flags=-ss
    service syslogd restart
}

update_sendmail()
{
    tell_status "turn off sendmail network listening"
    sysrc -f /etc/rc.conf sendmail_enable=NO
    service sendmail onestop
}

get_public_facing_nic()
{
    if [ "$1" = 'ipv6' ]; then
        PUBLIC_NIC=`netstat -rn | grep default | awk '{ print $4 }' | tail -n1`
    else
        PUBLIC_NIC=`netstat -rn | grep default | awk '{ print $4 }' | head -n1`
    fi
}

get_public_ip()
{
    get_public_facing_nic $1

    if [ "$1" = 'ipv6' ]; then
        PUBLIC_IP6=`ifconfig $PUBLIC_NIC | grep 'inet6' | grep -v fe80 | awk '{print $2}'`
    else
        PUBLIC_IP4=`ifconfig $PUBLIC_NIC | grep 'inet ' | awk '{print $2}'`
    fi
}

constrain_sshd_to_host()
{
    if ! sockstat -L | egrep '\*:22 '; then
        return
    fi

    get_public_ip
    get_public_ip ipv6
    local _sshd_conf="/etc/ssh/sshd_config"

    local _confirm_msg="
    To not interfere with the jails, sshd must be constrained to
    listening on your hosts public facing IP(s).

    Your public IPs are detected as $PUBLIC_IP4
        and $PUBLIC_IP6

    May I update $_sshd_conf?
    "
    dialog --yesno "$_confirm_msg" 13 70 || exit

    sed -i -e "s/#ListenAddress 0.0.0.0/ListenAddress $PUBLIC_IP4/" $_sshd_conf
    if [ -n "$PUBLIC_IP6" ]; then
        sed -i -e "s/#ListenAddress ::/ListenAddress $PUBLIC_IP6/" $_sshd_conf
    fi

    # grep ^Listen /etc/ssh/sshd_config
    service sshd restart
}

check_global_listeners()
{
    if sockstat -L | egrep '\*:[0-9]' | grep -v 123; then
        echo "oops!, you should not having anything listening
        on all your IP addresses!"
        exit 2
    fi
}

add_jail_nat()
{
    sysrc -f /etc/rc.conf pf_enable=YES

    grep -qs bruteforce /etc/pf.conf || tee -a /etc/pf.conf <<EO_PF_RULES
ext_if="$PUBLIC_NIC"
table <ext_ips> { $PUBLIC_IP4 $PUBLIC_IP6 }
table <bruteforce>  persist

# default route to the internet for jails
nat on \$ext_if from $JAIL_NET_PREFIX.0${JAIL_NET_MASK} to any -> (\$ext_if)

# POP3 & IMAP traffic to dovecot jail
rdr proto tcp from any to <ext_ips> port { 110 143 993 995 } -> $JAIL_NET_PREFIX.15

# SMTP traffic to the Haraka jail
rdr proto tcp from any to <ext_ips> port { 25 465 587 } -> $JAIL_NET_PREFIX.9

# HTTP traffic to HAproxy
rdr proto tcp from any to <ext_ips> port { 80 443 } -> $JAIL_NET_PREFIX.12

block in quick from <bruteforce>
EO_PF_RULES

    if ! (kldstat -m pf | grep pf); then
        kldload pf
    fi

    /etc/rc.d/pf restart
    pfctl -f /etc/pf.conf
}

install_jailmanage()
{
    pkg install -y ca_root_nss
    fetch -o /usr/local/sbin/jailmanage https://www.tnpi.net/computing/freebsd/jail_manage.txt
    chmod 755 /usr/local/sbin/jailmanage
}

set_jail_startup_order()
{
    fetch -o - http://mail-toaster.com/install/mt6-jail-rcd.txt | patch -d /
    #sysrc -f /etc/rc.conf jail_list="dns mysql vpopmail webmail haproxy clamav avg rspamd spamassassin haraka dspam monitor"
}

enable_jails()
{
    #set_jail_startup_order

    sysrc -f /etc/rc.conf jail_enable=YES

    if grep -sq 'exec' /etc/jail.conf; then
        return
    fi

    jail_conf_header
}

update_freebsd() {
    tell_status "updating FreeBSD with security patches"

    # remove 'src'
    sed -i .bak -e 's/^Components src .*/Components world kernel/' /etc/freebsd-update.conf
    freebsd-update fetch install

    tell_status "updating FreeBSD pkg collection"
    pkg update || exit

    tell_status "updating FreeBSD ports tree"
    portsnap fetch update || portsnap fetch extract
}

update_host() {
    update_freebsd
    update_host_ntpd
    update_syslogd
    update_sendmail
    constrain_sshd_to_host
    check_global_listeners
    add_jail_nat
    enable_jails
    install_jailmanage
}

update_host