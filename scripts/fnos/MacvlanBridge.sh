#!/bin/bash
cat << 'EOF' | sudo tee /etc/systemd/system/macvlan-shim.service > /dev/null
[Unit]
Description=Macvlan Bridge Shim for Docker
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

# 启动前尝试清理旧接口（忽略报错）
ExecStartPre=-/sbin/ip link del macvlan-shim

# 执行启动脚本（使用 - 忽略重复添加导致的报错）
ExecStart=-/sbin/ip link add macvlan-shim link enp2s0-ovs type macvlan mode bridge
ExecStart=-/sbin/ip addr add 192.168.11.220/32 dev macvlan-shim
ExecStart=/sbin/ip link set macvlan-shim up
ExecStart=-/sbin/ip route add 192.168.11.110/32 dev macvlan-shim
ExecStart=-/sbin/ip route add 192.168.11.111/32 dev macvlan-shim
# 停止时清理
ExecStop=-/sbin/ip route del 192.168.11.110/32 dev macvlan-shim
ExecStop=-/sbin/ip route del 192.168.11.111/32 dev macvlan-shim
ExecStop=-/sbin/ip link set macvlan-shim down
ExecStop=-/sbin/ip link del macvlan-shim

[Install]
WantedBy=multi-user.target
EOF

# 重载并启动服务

sudo systemctl daemon-reload
sudo systemctl enable macvlan-shim
sudo systemctl restart macvlan-shim