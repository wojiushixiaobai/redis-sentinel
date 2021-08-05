#!/bin/bash

##
# 不偷懒是不可能不偷懒的, 这辈子都不可能的.
# 什么叫懒人, 这就是了.

BASE_DIR=$(cd "$(dirname "$0")";pwd)
PROJECT_DIR=${BASE_DIR}
action=$1

cd ${PROJECT_DIR} || exit 1

if [ ! -f "$PROJECT_DIR/config.conf" ]; then
  echo -e "Error: No config file found."
  echo -e "You can run 'cp config_example.conf config.conf', and edit it."
  exit 1
else
  source ${PROJECT_DIR}/config.conf
fi

isRoot=`id -u -n | grep root | wc -l`
if [ "x$isRoot" != "x1" ]; then
  echo -e "[\033[31m ERROR \033[0m] 请用 root 用户执行安装脚本"
  exit 1
fi

if [ ! -f "/etc/redhat-release" ]; then
  echo -e "[\033[31m ERROR \033[0m] 操作系统类型版本不符合要求，请使用 CentOS 7/8"
  exit 1
fi

HOST_IP=$(hostname -I | cut -d ' ' -f1)

if [ ! -d "/sys/class/net/$INTERFACE" ]; then
  if [ "$(firewall-cmd --state)" == "running" ]; then
    INTERFACE=$(firewall-cmd --list-interfaces | cut -d ' ' -f1)
    echo -e "[\033[33m WARNING \033[0m] 已经替换 interfaces: $INTERFACE"
  else
    echo -e "[\033[31m ERROR \033[0m] 网卡 $INTERFACE 不存在, 请修正 config.conf 的网卡名称"
    exit 1
  fi
fi

function prepare_install() {
  if grep -q 'mirror.centos.org' /etc/yum.repos.d/CentOS-Base.repo; then
    curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.163.com/.help/CentOS7-Base-163.repo
    if [ ! -f "/etc/yum.repos.d/epel.repo" ]; then
      curl -o /etc/yum.repos.d/epel.repo https://demo.jumpserver.org/download/centos/7/epel.repo
    fi
  fi
  for app in epel-release wget make gcc-c++; do
    if [ ! "$(rpm -qa | grep ${app} )" ]; then
      yum -y install ${app}
    fi
  done
  if [ ! "$(rpm -qa | grep keepalived )" ]; then
    yum install -y keepalived
    systemctl enable keepalived
    mv /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak
  fi
  if [ "$(firewall-cmd --state)" == "running" ]; then
    if [ ! "$(firewall-cmd --list-services | grep redis)" ]; then
      firewall-cmd --permanent --zone=public --add-service=redis
      firewalld_flag=1
    fi
    if [ ! "$(firewall-cmd --list-protocol | grep vrrp)" ]; then
      firewall-cmd --permanent --zone=public --add-protocol=vrrp
      firewalld_flag=1
    fi
    if [ ! "$(firewall-cmd --list-ports | grep $SENTINEL_PORT)" ]; then
      firewall-cmd --permanent --zone=public --add-port=$SENTINEL_PORT/tcp
      firewalld_flag=1
    fi
    if [ "$firewalld_flag" ]; then
      firewall-cmd --reload
    fi
  fi
  if ! grep -q "vm.overcommit_memory" /etc/sysctl.conf; then
    echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
    sysctl_flag=1
  fi
  if ! grep -q "net.core.somaxconn" /etc/sysctl.conf; then
    echo "net.core.somaxconn = 1024" >> /etc/sysctl.conf
    sysctl_flag=1
  fi
  if ! grep -q "never" /sys/kernel/mm/transparent_hugepage/enabled; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
    chmod +x /etc/rc.d/rc.local
    echo "echo never > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.local
    sysctl_flag=1
  fi
  if [ "$sysctl_flag" ]; then
    sysctl -p
  fi
}

function install_redis() {
  if [ ! -d "/usr/local/redis" ]; then
    if [ ! -d "${PROJECT_DIR}/redis-${VERSION}" ]; then
      if [ ! -f "${PROJECT_DIR}/redis-${VERSION}.tar.gz" ]; then
        wget -O "${PROJECT_DIR}/redis-${VERSION}.tar.gz" https://download.redis.io/releases/redis-6.2.5.tar.gz || {
          rm -f "${PROJECT_DIR}/redis-${VERSION}.tar.gz"
          echo -e "[\033[31m ERROR \033[0m] redis-${VERSION}.tar.gz 下载失败, 请检查网络或者重试"
          exit 1
        }
      fi
      tar -xf "${PROJECT_DIR}/redis-${VERSION}.tar.gz" -C "${PROJECT_DIR}" || {
        rm -rf "${PROJECT_DIR}/redis-${VERSION}.tar.gz" "${PROJECT_DIR}/redis-${VERSION}"
        echo -e "[\033[31m ERROR \033[0m] redis-${VERSION}.tar.gz 解压失败, 请重试"
        exit 1
      }
    fi
    cd ${PROJECT_DIR}/redis-${VERSION} || exit 1
    make || {
      echo -e "[\033[31m ERROR \033[0m] make 失败, 请检查依赖包是否正常安装"
      exit 1
    }
    make install PREFIX=/usr/local/redis || {
      rm -rf /usr/local/redis
      echo -e "[\033[31m ERROR \033[0m] make install 失败, 请根据日志解决错误"
      exit 1
    }
  fi
  if [ ! -f "/etc/redis.conf" ]; then
    cp ${PROJECT_DIR}/redis-${VERSION}/redis.conf /etc/redis.conf
  fi
  if [ ! -f "/etc/redis-sentinel.conf" ]; then
    cp ${PROJECT_DIR}/redis-${VERSION}/sentinel.conf /etc/redis-sentinel.conf
  fi
  if [ ! -f "/etc/systemd/system/redis.service" ]; then
    cp ${PROJECT_DIR}/redis.service /etc/systemd/system/redis.service
  fi
  if [ ! -f "/etc/systemd/system/redis-sentinel.service" ]; then
    cp ${PROJECT_DIR}/redis-sentinel.service /etc/systemd/system/redis-sentinel.service
  fi
  if [ ! -d "/var/lib/redis" ]; then
    mkdir -p /var/lib/redis
  fi
  if [ ! -d "/var/log/redis" ]; then
    mkdir -p /var/log/redis
    echo > /var/log/redis/redis.log
  fi
  if ! command -v redis-cli >/dev/null; then
    \cp -rf /usr/local/redis/bin/redis-cli /usr/bin/
  fi
  systemctl daemon-reload
}

function config_redis() {
  if [ "$REDIS_PORT" != "6379" ]; then
    sed -i '/^#/!s/port 6379/port '$REDIS_PORT'/g' /etc/redis.conf
  fi
  sed -i "s@bind 127.0.0.1 .*@bind 0.0.0.0@g" /etc/redis.conf
  sed -i "s@protected-mode yes@protected-mode no@g" /etc/redis.conf
  sed -i "s@daemonize no@daemonize yes@g" /etc/redis.conf
  sed -i "s@supervised no@supervised systemd@g" /etc/redis.conf
  sed -i "s@pidfile /var/run/redis_6379.pid@pidfile /var/run/redis.pid@g" /etc/redis.conf
  sed -i 's@logfile ""@logfile /var/log/redis/redis.log@g' /etc/redis.conf
  sed -i "s@dir ./@dir /var/lib/redis@g" /etc/redis.conf
  sed -i "s@# repl-timeout 60@repl-timeout 60@g" /etc/redis.conf
  sed -i "s@# repl-ping-replica-period 10@repl-ping-replica-period 10@g" /etc/redis.conf
  sed -i "s@appendonly no@appendonly yes@g" /etc/redis.conf
  if ! grep -q "maxmemory $REDIS_MAXMEMORY" /etc/redis.conf; then
    if [ ! "$(cat /etc/redis.conf | grep -v ^\# | grep 'maxmemory ')" ]; then
      sed -i "s@# maxmemory .*@maxmemory $REDIS_MAXMEMORY@g" /etc/redis.conf
    else
      sed -i '/^#/!s@maxmemory .*@maxmemory '$REDIS_MAXMEMORY'@g' /etc/redis.conf
    fi
  fi
  if ! grep -q "maxmemory-policy allkeys-lru" /etc/redis.conf; then
    if [ ! "$(cat /etc/redis.conf | grep -v ^\# | grep 'maxmemory-policy ')" ]; then
      sed -i "s@# maxmemory-policy .*@maxmemory-policy allkeys-lru@g" /etc/redis.conf
    else
      sed -i '/^#/!s@maxmemory-policy .*@maxmemory-policy allkeys-lru@g' /etc/redis.conf
    fi
  fi
  if ! grep -q "requirepass $REDIS_PASSWORD" /etc/redis.conf; then
    if [ ! "$(cat /etc/redis.conf | grep -v ^\# | grep 'requirepass ')" ]; then
      sed -i "s@# requirepass .*@requirepass $REDIS_PASSWORD@g" /etc/redis.conf
    else
      sed -i '/^#/!s@requirepass .*@requirepass '$REDIS_PASSWORD'@g' /etc/redis.conf
    fi
  fi
  if ! grep -q "masterauth $REDIS_PASSWORD" /etc/redis.conf; then
    if [ ! "$(cat /etc/redis.conf | grep -v ^\# | grep 'masterauth ')" ]; then
      sed -i "s@# masterauth .*@masterauth $REDIS_PASSWORD@g" /etc/redis.conf
    else
      sed -i '/^#/!s@masterauth .*@masterauth '$REDIS_PASSWORD'@g' /etc/redis.conf
    fi
  fi
  if [ "$HOST_IP" != "$MASTER_HOST" ]; then
    if ! grep -q "replicaof $MASTER_HOST $REDIS_PORT" /etc/redis.conf; then
      if [ ! "$(cat /etc/redis.conf | grep -v ^\# | grep 'replicaof ')" ]; then
        sed -i "s@# replicaof .*@replicaof $MASTER_HOST $REDIS_PORT@g" /etc/redis.conf
      else
        sed -i '/^#/!s@replicaof .*@replicaof '$MASTER_HOST' '$REDIS_PORT'@g' /etc/redis.conf
      fi
    fi
  fi
}

function config_sentinel() {
  sed -i "s@# protected-mode no@protected-mode no@g" /etc/redis-sentinel.conf
  sed -i "s@daemonize no@daemonize yes@g" /etc/redis-sentinel.conf
  sed -i 's@logfile ""@logfile /var/log/redis/sentinel.log@g' /etc/redis-sentinel.conf
  if ! grep -q "sentinel monitor $SENTINEL_NAME $MASTER_HOST $REDIS_PORT $SENTINEL_QUORUM" /etc/redis-sentinel.conf; then
    sed -i '/^#/!s@sentinel monitor .*@sentinel monitor '$SENTINEL_NAME' '$MASTER_HOST' '$REDIS_PORT' '$SENTINEL_QUORUM'@g' /etc/redis-sentinel.conf
  fi
  sed -i "s@sentinel down-after-milliseconds mymaster 30000@sentinel down-after-milliseconds $SENTINEL_NAME 5000@g" /etc/redis-sentinel.conf
  if ! grep -q "sentinel auth-pass $SENTINEL_NAME $REDIS_PASSWORD" /etc/redis-sentinel.conf; then
    if [ ! "$(cat /etc/redis-sentinel.conf | grep -v ^\# | grep 'sentinel auth-pass ')" ]; then
      sed -i "s@# sentinel auth-pass <master-name> <password>@sentinel auth-pass $SENTINEL_NAME $REDIS_PASSWORD@g" /etc/redis-sentinel.conf
    else
      sed -i '/^#/!s@sentinel auth-pass .*@sentinel auth-pass '$SENTINEL_NAME' '$REDIS_PASSWORD'@g' /etc/redis-sentinel.conf
    fi
  fi
  if ! grep -q "sentinel parallel-syncs $SENTINEL_NAME $SENTINEL_NUMREPLICAS" /etc/redis-sentinel.conf; then
    if  [ ! "$(cat /etc/redis-sentinel.conf | grep -v ^\# | grep 'sentinel parallel-syncs ')" ]; then
      sed -i "s@# sentinel parallel-syncs .*@sentinel parallel-syncs $SENTINEL_NAME $SENTINEL_NUMREPLICAS@g" /etc/redis-sentinel.conf
    else
      sed -i '/^#/!s@sentinel parallel-syncs .*@sentinel parallel-syncs '$SENTINEL_NAME' '$SENTINEL_NUMREPLICAS'@g' /etc/redis-sentinel.conf
    fi
  fi
}

function config_keepalived() {
  cat > /etc/keepalived/keepalived.conf << "EOF"
! Configuration File for keepalived

global_defs {
  router_id redis
  script_user root
}

vrrp_script chk_redis {
  script /usr/libexec/keepalived/redis_check.sh
  interval 1
  fall 2
  rise 2
}

vrrp_instance redis {
  state BACKUP
  interface eth0
  virtual_router_id 100
  priority 100
  nopreempt
  advert_int 1

  authentication {
    auth_type PASS
    auth_pass weakPassword
  }

  virtual_ipaddress {
    192.168.101.10
  }

  track_script {
    chk_redis
  }
}
EOF
  cat > /usr/libexec/keepalived/redis_check.sh << "EOF"
#!/bin/bash
##

REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=weakPassword

if [ ! "$(redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASSWORD info Replication | grep role:master)" ]; then
  exit 1
fi
EOF
  sed -i "s@router_id redis@router_id $HOST_IP@g" /etc/keepalived/keepalived.conf
  sed -i "s@interface eth0@interface $INTERFACE@g" /etc/keepalived/keepalived.conf
  sed -i "s@virtual_router_id .*@virtual_router_id $VIRTUAL_ROUTER_ID@g" /etc/keepalived/keepalived.conf
  sed -i "s@auth_pass .*@auth_pass $REDIS_PASSWORD@g" /etc/keepalived/keepalived.conf
  sed -i "s@192.168.101.10@$VIP@g" /etc/keepalived/keepalived.conf
  if [ "$HOST_IP" != "$MASTER_HOST" ]; then
    sed -i "s@priority 100@priority 90@g" /etc/keepalived/keepalived.conf
  fi

  sed -i "s@REDIS_PORT=.*@REDIS_PORT=$REDIS_PORT@g" /usr/libexec/keepalived/redis_check.sh
  sed -i "s@REDIS_PASSWORD=.*@REDIS_PASSWORD=$REDIS_PASSWORD@g" /usr/libexec/keepalived/redis_check.sh
  chmod 755 /usr/libexec/keepalived/redis_check.sh
}

function message() {
    echo ""
    echo -e "Redis 部署完成"
    echo -ne "请执行"
    echo -ne "\033[33m ./install.sh start \033[0m"
    echo -e "启动 \n"
}

function install() {
  prepare_install
  install_redis
  config_redis
  config_sentinel
  config_keepalived
  message
}

function start() {
  if [ ! "$(systemctl status redis | grep Active | grep running)" ]; then
    systemctl start redis
  fi
  if [ ! "$(systemctl status redis-sentinel | grep Active | grep running)" ]; then
    systemctl start redis-sentinel
  fi
  if [ ! "$(systemctl status keepalived | grep Active | grep running)" ]; then
    systemctl start keepalived
  fi
}

function stop() {
  systemctl stop keepalived
  systemctl stop redis
  systemctl stop redis-sentinel
}

function restart() {
  stop
  start
}

function status() {
  echo
  echo -ne "Redis Service       \t.... "
  redis-cli -h 127.0.0.1 -p $REDIS_PORT -a $REDIS_PASSWORD info >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo -e "[\033[31m ERROR \033[0m]"
  else
    echo -e "[\033[32m OK \033[0m]"
  fi

  echo -ne "Sentinel Service    \t.... "
  redis-cli -h 127.0.0.1 -p $SENTINEL_PORT -a $REDIS_PASSWORD info >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo -e "[\033[31m ERROR \033[0m]"
  else
    echo -e "[\033[32m OK \033[0m]"
  fi

  echo -ne "Keepalived Service  \t.... "
  systemctl status keepalived | grep Active | grep running >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo -e "[\033[31m ERROR \033[0m]"
  else
    echo -e "[\033[32m OK \033[0m]"
  fi

  echo
  if [ "$(hostname -I | grep $VIP)" ]; then
    echo -e "[\033[32m role: master \033[0m]"
  else
    echo -e "[\033[33m role: slave \033[0m]"
  fi

  echo
  redis-cli -h 127.0.0.1 -p $REDIS_PORT -a $REDIS_PASSWORD info Replication 2>/dev//null

  echo
  redis-cli -h 127.0.0.1 -p $SENTINEL_PORT -a $REDIS_PASSWORD info sentinel 2>/dev//null
}

function uninstall() {
  stop
  yum remove -y keepalived redis5
  rm -f /etc/redis.conf
  rm -f /etc/redis-sentinel.conf
  rm -f /etc/keepalived/keepalived.conf
  rm -f /usr/libexec/keepalived/redis_check.sh
}

function reset() {
  uninstall
  install
}

function usage() {
  echo
  echo "Redis 部署安装脚本"
  echo
  echo "Usage: "
  echo "  install [COMMAND] ..."
  echo "  install --help"
  echo
  echo "Commands: "
  echo "  install      安装 Redis"
  echo "  start        启动 Redis"
  echo "  stop         停止 Redis"
  echo "  status       检查 Redis"
  echo "  restart      重启 Redis"
  echo "  uninstall    卸载 Redis"
  echo "  reset        重置 Redis"
}

function main() {
  case "${action}" in
    install)
      install
      ;;
    uninstall)
      uninstall
      ;;
    start)
      start
      ;;
    stop)
      stop
      ;;
    status)
      status
      ;;
    restart)
      restart
      ;;
    reset)
      reset
      ;;
    --help)
      usage
      ;;
    -h)
      usage
      ;;
    *)
      echo -e "install: unknown COMMAND: '$action'"
      echo -e "See 'install --help' \n"
      usage
  esac
}

main
