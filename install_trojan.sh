#!/bin/bash

function prompt() {
    while true; do
        read -p "$1 [y/N] " yn
        case $yn in
            [Yy] ) return 0;;
            [Nn]|"" ) return 1;;
        esac
    done
}

blue(){
    echo -e "\033[34m$1\033[0m"
}
green(){
    echo -e "\033[32m$1\033[0m"
}
red(){
    echo -e "\033[31m$1\033[0m"
}
yellow(){
    echo -e "\033[33m$1\033[0m"
}

if [[ $(id -u) != 0 ]]; then
    echo Please run this script as root.
    exit 1
fi

if [ ! -e '/etc/redhat-release' ]; then
red "==============="
red " 仅支持CentOS7"
red "==============="
exit
fi

if  [ -n "$(grep ' 6\.' /etc/redhat-release)" ] ;then
red "==============="
red " 仅支持CentOS7"
red "==============="
exit
fi

NAME=trojan
VERSION=1.14.0
TARBALL="$NAME-$VERSION-linux-amd64.tar.xz"
DOWNLOADURL="https://github.com/trojan-gfw/$NAME/releases/download/v$VERSION/$TARBALL"
TMPDIR="$(mktemp -d)"
INSTALLPREFIX=/usr/local/$NAME
SYSTEMDPREFIX=/etc/systemd/system

BINARYPATH="$INSTALLPREFIX/bin/$NAME"
CONFIGDIR="$INSTALLPREFIX/etc"
CONFIGPATH="$CONFIGDIR/config.json"
SYSTEMDPATH="$SYSTEMDPREFIX/$NAME.service"

SSLDIR="$INSTALLPREFIX/ssl"
KEYPATH="$SSLDIR/private.key"
CERPATH="$SSLDIR/fullchain.cer"

if ! [[ -d $CONFIGDIR ]];then
  mkdir -p $CONFIGDIR
fi

if ! [[ -d $SSLDIR ]];then
  mkdir -p $SSLDIR
fi

#SSLDIR=$(echo $INSTALLPREFIX/ssl | sed 's#\/#\\\/#g')

NGINX=/usr/local/openresty/nginx
WEBROOT=$NGINX/html/

function disable_selinux() {
  CHECK=$(grep SELINUX= /etc/selinux/config | grep -v "#")
  if [ "$CHECK" == "SELINUX=enforcing" ]; then
      sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
      setenforce 0
  fi
  if [ "$CHECK" == "SELINUX=permissive" ]; then
      sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
      setenforce 0
  fi
}

# 安装nginx
function install_nginx() {
  if [[ -f $NGINX/sbin/nginx ]]; then
    blue "已经安装了nginx"	
  else
    green "=========================================="
    green "开始安装nginx"
    green "=========================================="	
    yum -y install bind-utils wget unzip zip curl tar yum-utils 2>&1>/dev/null
    yum-config-manager --add-repo https://openresty.org/package/centos/openresty.repo 2>&1>/dev/null
    yum install -y openresty 
    systemctl enable openresty
    systemctl start openresty
  fi
}

# 检测证书是否过期
function check_expired() {
  cer_path=$1
  if ! [ -f $cer_path ]; then
    echo '证书不存在'
    return 0;
  fi
  end_time=$(openssl x509 -in $cer_path -noout -dates | grep 'notAfter' | awk -F '=' '{print $2}')
  current=`date "+%Y-%m-%d %H:%M:%S"`
  end_times=`date -d "$end_time" +%s`
  current_times=$(date -d "$current" +%s)

  let left_time=$end_times-$current_times
  days=`expr $left_time / 86400`
  if [ $days > 3 ];then
    echo '证书有效'
    return 1;
  else
    echo '证书过期'
    return 0;
  fi
}

# 安装证书
function install_cert() {
  if ! [ -f ~/.acme.sh/acme.sh ];then
    curl https://get.acme.sh | sh
  fi
  green "======================="
  yellow "请输入绑定到本VPS的域名"
  green "======================="
  read domain
  real_addr=`ping ${domain} -c 1 | sed '1{s/[^(]*(//;s/).*//;q}'`
  local_addr=`curl ipv4.icanhazip.com`
  if ! [ $real_addr == $local_addr ] ; then
    red "VPS域名不匹配"
    exit
  fi
  green $domain
  if check_expired $CERPATH;then
    ~/.acme.sh/acme.sh  --issue  -d $domain  --webroot $WEBROOT
    ~/.acme.sh/acme.sh  --installcert  -d  $domain   \
    --key-file   $KEYPATH \
    --fullchain-file $CERPATH \
	--reloadcmd "systemctl restart trojan"
  fi
}
# 安装 trojan
function install_trojan() {
  disable_selinux
  install_nginx
#  install_cert  
  blue "Entering temp directory $TMPDIR..."
  cd "$TMPDIR"

  blue "Downloading $NAME $VERSION..."
  curl -LO "$DOWNLOADURL" || wget "$DOWNLOADURL"

  blue "Unpacking $NAME $VERSION..."
  tar xf "$TARBALL"
  cd "$NAME"

  blue "Installing $NAME $VERSION to $BINARYPATH..."
  install -Dm755 "$NAME" "$BINARYPATH"

  blue "Installing $NAME server config to $CONFIGPATH..."

  if ! [[ -f "$CONFIGPATH" ]] || prompt "The server config already exists in $CONFIGPATH, overwrite?"; then
    trojan_passwd=$(cat /dev/urandom | head -1 | md5sum | head -c 8)
    red "连接密码:$trojan_passwd"
    cat > "$CONFIGPATH" << EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": 443,
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": [
        "$trojan_passwd"
    ],
    "log_level": 1,
    "ssl": {
        "cert": "$CERPATH",
        "key": "$KEYPATH",
        "key_password": "",
        "cipher": "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256",
        "cipher_tls13":"TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
        "prefer_server_cipher": true,
        "alpn": [
            "http/1.1",
            "h2"
        ],
        "reuse_session": true,
        "session_ticket": false,
        "session_timeout": 600,
        "plain_http_response": "",
        "curves": "",
        "dhparam": ""
    },
    "tcp": {
        "prefer_ipv4": false,
        "no_delay": true,
        "keep_alive": true,
        "reuse_port": false,
        "fast_open": false,
        "fast_open_qlen": 20
    },
    "mysql": {
        "enabled": false,
        "server_addr": "127.0.0.1",
        "server_port": 3306,
        "database": "trojan",
        "username": "trojan",
        "password": ""
    }
}
EOF

  else
    blue "Skipping installing $NAME server config..."
  fi

  if [[ -d "$SYSTEMDPREFIX" ]]; then
    green "Installing $NAME systemd service to $SYSTEMDPATH..."
    if ! [[ -f "$SYSTEMDPATH" ]] || prompt "The systemd service already exists in $SYSTEMDPATH, overwrite?"; then
        cat > "$SYSTEMDPATH" << EOF
[Unit]
Description=$NAME
Documentation=https://trojan-gfw.github.io/$NAME/config https://trojan-gfw.github.io/$NAME/
After=network.target network-online.target nss-lookup.target mysql.service mariadb.service mysqld.service

[Service]
Type=simple
StandardError=journal
ExecStart="$BINARYPATH" "$CONFIGPATH"
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

      blue "Reloading systemd daemon..."
      systemctl daemon-reload
    else
      blue "Skipping installing $NAME systemd service..."
    fi
  fi
  # 安装证书
  install_cert  
  systemctl restart trojan
  systemctl enable trojan

  blue "Deleting temp directory $TMPDIR..."
  rm -rf "$TMPDIR"
  green "安装完成!"
}

function remove_trojan(){
    red "================================"
    red "即将卸载trojan"
    red "同时卸载安装的nginx"
    red "================================"
    systemctl stop trojan
    systemctl disable trojan
    rm -f $SYSTEMDPATH
    rm -rf $INSTALLPREFIX
    systemctl stop openresty
    systemctl disable openresty
    yum remove -y openresty
    green "=============="
    green "trojan删除完毕"
    green "=============="
}
start_menu(){
    clear
    green " ===================================="
    green " 介绍：一键安装trojan      "
    green " 系统：>=centos7                       "
    green " ===================================="
    echo
    green " 1. 安装trojan"
    red " 2. 卸载trojan"
    yellow " 0. 退出脚本"
    echo
    read -p "请输入数字:" num
    case "$num" in
    1)
    install_trojan
    ;;
    2)
    remove_trojan 
    ;;
    0)
    exit 1
    ;;
    *)
    clear
    red "请输入正确数字"
    sleep 1s
    start_menu
    ;;
    esac
}

start_menu
