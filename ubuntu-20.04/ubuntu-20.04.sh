#!/bin/bash
# Ubuntu 20.04 Strongswan VPN server - ikev2
# Run this script as root

echo "### Strongswan Server install - ikev2 ###"
echo "### Ubuntu 20.04 ###"
echo "------------------------------------"

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

apt update -y
apt install -y \
    strongswan \
    strongswan-pki \
    libcharon-extra-plugins \
    libcharon-extauth-plugins \
    net-tools \
    curl

IPADDR=$(curl -s https://api.ipify.org)

mkdir -p ~/pki/{cacerts,certs,private}

pki --gen --type rsa --size 4096 --outform pem > ~/pki/private/ca-key.pem
pki --self --ca --lifetime 3650 --in ~/pki/private/ca-key.pem --type rsa --dn "CN=VPN CA $IPADDR" --outform pem > ~/pki/cacerts/ca-cert.pem
pki --gen --type rsa --size 4096 --outform pem > ~/pki/private/server-key.pem
pki --pub --in ~/pki/private/server-key.pem --type rsa \
    | pki --issue --lifetime 1825 \
        --cacert ~/pki/cacerts/ca-cert.pem \
        --cakey ~/pki/private/ca-key.pem \
        --dn "CN=$IPADDR" --san=$IPADDR --san=@$IPADDR  \
        --flag serverAuth --flag ikeIntermediate --outform pem \
    >  ~/pki/certs/server-cert.pem

cp -r ~/pki/* /etc/ipsec.d/

mv /etc/ipsec.conf{,.original}

# Config
echo \
"config setup
    charondebug="ike 2, knl 2, cfg 2"
    strictcrlpolicy=no
    uniqueids=no
    cachecrls=no

conn ikev2-vpn
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    dpdaction=clear
    dpddelay=300s
    rekey=no
    left=%any
    leftid=$IPADDR
    leftcert=server-cert.pem
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    right=%any
    rightid=%any
    rightauth=eap-mschapv2
    rightsourceip=10.10.10.0/24
    rightdns=8.8.8.8,8.8.4.4
    rightsendcert=never
    eap_identity=%identity
    ike=chacha20poly1305-sha512-curve25519-prfsha512,aes256gcm16-sha384-prfsha384-ecp384,aes256-sha1-modp1024,aes256-sha256-modp1024,aes256-sha256-modp2048,aes128-sha1-modp1024,3des-sha1-modp1024!
    esp=chacha20poly1305-sha512,aes256gcm16-ecp384,aes256-sha256,aes256-sha1,3des-sha1!" \
    > /etc/ipsec.conf

mv /etc/ipsec.secrets{,.original}
echo ': RSA "server-key.pem"' > /etc/ipsec.secrets
user1=`< /dev/urandom tr -dc a-z | head -c6`
user2=`< /dev/urandom tr -dc a-z | head -c6`
pass1=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c10`
pass2=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c10`
echo "$user1 : EAP \"$pass1\"" >> /etc/ipsec.secrets
echo "$user2 : EAP \"$pass2\"" >> /etc/ipsec.secrets
user1='' && user2='' && pass1='' && pass2=''

systemctl restart strongswan-starter
systemctl enable strongswan-starter

ufw allow OpenSSH && echo "y" | ufw enable && ufw allow 500,4500/udp

ifc=$(route | grep '^default' | grep -o '[^ ]*$')
cp /etc/ufw/before.rules /etc/ufw/before.rules.bak

mv /etc/ufw/before.rules{,.temp} && \
echo \
"*nat
-A POSTROUTING -s 10.10.10.0/24 -o $ifc -m policy --pol ipsec --dir out -j ACCEPT
-A POSTROUTING -s 10.10.10.0/24 -o $ifc -j MASQUERADE
COMMIT

*mangle
-A FORWARD --match policy --pol ipsec --dir in -s 10.10.10.0/24 -o $ifc -p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss 1361:1536 -j TCPMSS --set-mss 1360
COMMIT
" \
> /etc/ufw/before.rules && \
cat /etc/ufw/before.rules.temp >> /etc/ufw/before.rules && \
rm -f /etc/ufw/before.rules.temp

sed -n 'H;${x;s/^\n//;s/..allow all on loopback.*$/\-A ufw\-before\-forward \-\-match policy \-\-pol ipsec \-\-dir in \-\-proto esp \-s 10.10.10.0\/24 \-j ACCEPT\n&/;p;}' \
    /etc/ufw/before.rules > /etc/ufw/before.rules.tmp && \
sed -n 'H;${x;s/^\n//;s/..allow all on loopback.*$/\-A ufw\-before\-forward \-\-match policy \-\-pol ipsec \-\-dir out \-\-proto esp \-d 10.10.10.0\/24 \-j ACCEPT\n&/;p;}' \
    /etc/ufw/before.rules.tmp > /etc/ufw/before.rules && \
rm -f /etc/ufw/before.rules.tmp

echo \
"net/ipv4/ip_forward=1
net/ipv4/conf/all/accept_redirects=0
net/ipv4/conf/all/send_redirects=0
net/ipv4/ip_no_pmtu_disc=1
" \ >> /etc/ufw/sysctl.conf

ufw disable
echo "y" | ufw enable

echo "
Passwords here - /etc/ipsec.secrets. You can change it. Restart if you will change - systemctl restart strongswan-starter.

Import the certificate to your device /etc/ipsec.d/cacerts/ca-cert.pem

Use this IP for connection - $IPADDR
Type - ikev2.

If you use external firewall, you must open ports 500/UDP,4500/UDP.
"

cat /etc/ipsec.d/cacerts/ca-cert.pem
cat /etc/ipsec.secrets
