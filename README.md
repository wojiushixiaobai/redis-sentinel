# redis-sentinel

## 支持的操作系统

- [x] CentOS 7
- [x] CentOS 8

## 安装方法

- 准备好至少三台服务器, 三台服务器的配置文件一样, 设置好第一台后可以直接拷贝 config.conf 到其他服务器运行即可。

```bash
git clone --depth=1 https://github.com/wojiushixiaobai/redis-sentinel
cd redis-sentinel
cp config_example.conf config.conf
vi config.conf
```
```vim
VERSION=6.2.5                # Redis 版本号

# Redis
MASTER_HOST=192.168.101.11   # 修改成你需要用作 master 的 redis 服务器 ip
REDIS_PORT=6379              # Redis 使用的端口
REDIS_PASSWORD=weakPassword  # Redis 密码

# Redis Sentinel
SENTINEL_PORT=26379          # Sentinel 使用的端口
SENTINEL_NAME=mymaster       # 集群名称
SENTINEL_QUORUM=1            # 集群服务器数量超过 3 个设置为 2
SENTINEL_NUMREPLICAS=1       # 主备切换时 1 个从节点不可使用

# Keepalived
INTERFACE=eth0               # 物理网卡名称
VIP=192.168.101.10           # Keepalived 集群 vip
VIRTUAL_ROUTER_ID=100        # 同一个局域网多个 Keepalived 集群 id 不可重复
```

### 安装

```bash
./install.sh install
```

### 启动

```bash
./install.sh start
```

### 检查

```bash
./install.sh status
```

### 停止
```bash
./install.sh restart
```

### 帮助
```bash
./install --help
```
