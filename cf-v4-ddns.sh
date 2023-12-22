#!/usr/bin/env bash

# 原理：
# 通过 CFZONE_ID 和 CFRECORD_NAME 获取 CFRECORD_ID，然后使用CF的API修改dns
# -c 参数可以给eth0添加一个/128的IPv6

# crontab：
# 0 * * * * /path/cf-ddns.sh # 每小时更新一次ddns
# 0 * * * * /path/cf-ddns.sh -c # 每小时换一个IPv6/128并更新ddns

# 参考：
# https://github.com/yulewang/cloudflare-api-v4-ddns

# API Token，需要ZONE.DNS.EDIT权限
CFTOKEN="xxxxxxxx"
# Zone ID，在根域名Overview的右下角
CFZONE_ID="xxxxxxxx"
# 二级域名
CFRECORD_NAME="ddns.example.com"
# A：IPv4，AAAA：IPv6
CFRECORD_TYPE="A"
# 120 - 86400s
CFTTL="120"

# IPv6前缀
prefex=":"

# 在$HOME文件夹下维护一个记录文件 .ddns.dat，格式如下：
# OLD_IPv6: 上一次添加的IPv6/128
# OLD_WANIP: 上一次获取的公网IP
# CFRECORD_ID: 一次获取之后复用
DDNS_FILE="$HOME/.ddns.dat"
if [ -f $DDNS_FILE ]; then
  OLD_IPv6=$(awk 'NR==1' $DDNS_FILE)
  OLD_WANIP=$(awk 'NR==2' $DDNS_FILE)
  CFRECORD_ID=$(awk 'NR==3' $DDNS_FILE)
else
  echo "No database, created already."
  touch $DDNS_FILE
fi

# 获取 CFRECORD_ID
if [ ${#CFRECORD_ID} -ne 32 ]; then
  CFRECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME" \
                    -H "Authorization: Bearer $CFTOKEN" \
                    -H "Content-Type: application/json"  | grep -Po '(?<="id":")[^"]*' | head -1 )
  sed -i "3s/.*/$CFRECORD_ID/" $DDNS_FILE
fi

# 生成随机IPv6/128地址并赋给eth0
if [ "$1" = "-c" ]; then
    # 删除上一次添加的IPv6
    ip -6 addr del $OLD_IPv6 dev eth0 >/dev/null 2>&1
    NEW_IPv6=$prefex$(openssl rand -hex 8 | sed 's/\(....\)/\1:/g; s/.$//')
    sed -i "1s/.*/$NEW_IPv6/" $DDNS_FILE
    ip -6 addr add $NEW_IPv6 dev eth0
    # 等待10秒，使新IP生效
    sleep 10
fi

if [ "$CFRECORD_TYPE" = "A" ]; then
  WANIPSITE="http://ipv4.ip.sb"
elif [ "$CFRECORD_TYPE" = "AAAA" ]; then
  WANIPSITE="http://ipv6.ip.sb"
else
  echo "$CFRECORD_TYPE specified is invalid, CFRECORD_TYPE can only be A(for IPv4)|AAAA(for IPv6)"
  exit 1
fi

# Get current and old WAN ip
WANIP=$(curl -s $WANIPSITE)

# If WAN IP is unchanged, exit here
if [ "$WANIP" = "$OLD_WANIP" ]; then
  echo "WAN IP Unchanged, exit."
  exit 0
fi

# If WAN is changed, update cloudflare
echo "Updating DNS to $WANIP"

RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
                -H "Authorization: Bearer $CFTOKEN" \
                -H "Content-Type: application/json" \
                --data "{\"id\":\"$CFZONE_ID\",\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WANIP\", \"ttl\":$CFTTL}")

if [ "$RESPONSE" != "${RESPONSE%success*}" ] && [ "$(echo $RESPONSE | grep "\"success\":true")" != "" ]; then
  echo "😊 Updated succesfuly!"
  sed -i "2s/.*/$WANIP/" $DDNS_FILE
else
  echo '🤡 Something went wrong...'
  echo "Response: $RESPONSE"
  exit 1
fi
