#!/bin/sh

################################################################
#### Deps: tmux, tcpdump, hostapd, dnsmasq, running as root ####
################################################################

session='Apmon'

# configuration dir, default is right here
conf_dir="$(dirname "$0")"
conf_file='ap.conf'

# enable tcpdump monitoring
tcpdump_enabled=1

ip_addr='192.168.50.1'
netmask='/24'

dhcp_min='192.168.50.10'
dhcp_max='192.168.50.100'

lease_time='12h'

dns1='8.8.8.8'
dns2='8.8.4.4'

wifi_if='wlan0'
wifi_driver='nl80211'

ssid='Test_Network'
wpa_password='password123'

# prefix to your usb tether interface,
# e.g. mine is something along the lines of
# 'enx7fe9...'.
usb_if_prefix='enx'
usb_if="$(ip link | grep -Po "$usb_if_prefix[0-9a-zA-Z]+")"

err() {
    printf "%s\n" "$1"
	exit
}

build_sed_script() {
    sedscript=
    while read -r pattern
    do
        sedscript="$sedscript""$pattern"
    done
}

build_network_config() {
    
    build_sed_script <<EOF
s/interface=/interface=$wifi_if/;
s/driver=/driver=$wifi_driver/;
s/ssid=/ssid=$ssid/;
s/wpa_passphrase=/wpa_passphrase=$wpa_passphrase/;
EOF
    sed -e "$sedscript" ap.conf.in > "$conf_dir"/"$conf_file"
}

configure_wifi_iface() {
    ip link set "$wifi_if" down
    ip addr flush                    dev "$wifi_if"
    ip addr add "$ip_addr""$netmask" dev "$wifi_if"
    ip link set "$wifi_if" up
}

tmux_setup_session() {
    tmux new-session -d -s "$session"
    tmux rename-window -t 0 'Main'

    # initialize hostapd
    tmux new-window -t "$session":1 -n 'Hostapd'
    tmux send-keys  -t 'Hostapd' "hostapd $conf_dir/$conf_filename" C-m

    sleep 1

    # setup dnsmasq for managing dhcp and dns
    # quick reminder that probably this won't work in a normal user distro,
    # since it requires that the default dns port (53) is open. One option is
    # stopping 'systemd-resolved'.
    tmux new-window -t "$session":2 -n 'Dnsmasq'
    tmux send-keys  -t "Dnsmasq" "dnsmasq -i $wifi_if --bind-interfaces -d --listen-address=$ip_addr --dhcp-range=$dhcp_min,$dhcp_max,$lease_time --server=$dns1 --server=$dns2" C-m

    # initialize tcpdump, optional, hence the flag i set to enable/disable it,
    # but it can be especially useful here since sometimes stuff just decides
    # to not work, and you can debug it here
    if [ "$tcpdump_enabled" -eq 1 ]; then
        tmux new-window -t "$session":3 -n 'Tcpdump'
        tmux send-keys  -t 'Tcpdump' "tcpdump" C-m
    fi
}

setup_ip_forwarding() {
    # important step to actually enable all this
    sysctl -w net.ipv4.ip_forward=1

    # reset
    iptables -t nat -F
    iptables -F

    iptables -t nat -A POSTROUTING           -o "$usb_if"  -j MASQUERADE
    iptables        -A FORWARD -i "$wifi_if" -o "$usb_if"  -j ACCEPT
    iptables        -A FORWARD -i "$usb_if"  -o "$wifi_if" -m state --state RELATED,ESTABLISHED -j ACCEPT
}

[ "$EUID" -ne 0 ] && err 'Please run as root'
[ -z "$iface"   ] && err 'No usb tether interface found'

build_network_config
configure_wifi_iface

setup_ip_forwarding

sleep 1

tmux_setup_session
tmux attach-session -t "$session":0

