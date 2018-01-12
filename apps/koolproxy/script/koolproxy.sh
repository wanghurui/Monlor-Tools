#!/bin/ash /etc/rc.common
monlorpath=$(uci -q get monlor.tools.path)
[ $? -eq 0 ] && source "$monlorpath"/scripts/base.sh || exit

START=95                                             
SERVICE_USE_PID=1                                    
SERVICE_WRITE_PID=1                                  
SERVICE_DAEMONIZE=1 

service=KoolProxy
appname=koolproxy
EXTRA_COMMANDS=" status backup recover"
EXTRA_HELP="        status  Get $appname status"
BIN=$monlorpath/apps/$appname/bin/$appname
LOG=/var/log/$appname.log
CONF=$monlorpath/apps/$appname/config/kpcontrol.conf
koolproxy_policy=`uci -q get monlor.$appname.mode` 

start_koolproxy () {
    logsh "【$service】" "开启$appname主进程..."
    EXT_ARG=""
    [ "$koolproxy_policy" == "1" ] && logsh "【$service】" "启动$appname为全局模式！"
    [ "$koolproxy_policy" == "2" ] && logsh "【$service】" "启动$appname为黑名单模式！"
    [ "$koolproxy_policy" == "3" ] && EXT_ARG="-e" && logsh "【$service】" "启动$appname为视频模式！"
    $BIN $EXT_ARG -c 4 -d -l $LOG
}

add_ipset_conf () {
    if [ "$koolproxy_policy" == "2" ]; then
        logsh "【$service】" "添加黑名单软链接..."
        rm -rf /tmp/etc/dnsmasq.d/koolproxy_ipset.conf
        ln -sf $monlorpath/apps/koolproxy/bin/data/koolproxy_ipset.conf /tmp/etc/dnsmasq.d/koolproxy_ipset.conf
        dnsmasq_restart=1
    fi
}

remove_ipset_conf () {
    if [ -L "/tmp/etc/dnsmasq.d/koolproxy_ipset.conf" ]; then
        logsh "【$service】" "移除黑名单软链接..."
        rm -rf /tmp/etc/dnsmasq.d/koolproxy_ipset.conf
    fi
}

restart_dnsmasq () {
    if [ "$dnsmasq_restart" == "1" ]; then
        logsh "【$service】" "重启dnsmasq进程..."
        /etc/init.d/dnsmasq restart > /dev/null 2>&1
    fi
}

create_ipset () {
    logsh "【$service】" "创建ipset名单..."
    ipset -N white_kp_list nethash
    ipset -N black_koolproxy iphash
}

add_white_black_ip(){
    ip_lan="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4"
    for ip in $ip_lan
    do
        ipset -A white_kp_list $ip >/dev/null 2>&1

    done
    ipset -A black_koolproxy 110.110.110.110 >/dev/null 2>&1
}

get_mode_name() {
    case "$1" in
        0)
            echo "不过滤"
        ;;
        1)
            echo "http模式"
        ;;
        2)
            echo "http + https"
        ;;
    esac
}

get_jump_mode () {
    case "$1" in
        0)
            echo "-j"
        ;;
        *)
            echo "-g"
        ;;
    esac
}

get_action_chain () {
    case "$1" in
        0)
            echo "RETURN"
        ;;
        1)
            echo "KOOLPROXY_HTTP"
        ;;
        2)
            echo "KOOLPROXY_HTTPS"
        ;;
    esac
}

factor () {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo ""
    else
        echo "$2 $1"
    fi
}

flush_nat () {
    logsh "【$service】" "移除nat规则..."
    cd /tmp
    iptables -t nat -S | grep -E "KOOLPROXY|KOOLPROXY_HTTP|KOOLPROXY_HTTPS" | sed 's/-A/iptables -t nat -D/g'|sed 1,3d > clean.sh && chmod 777 clean.sh && ./clean.sh && rm clean.sh
    iptables -t nat -X KOOLPROXY > /dev/null 2>&1
    iptables -t nat -X KOOLPROXY_HTTP > /dev/null 2>&1
    iptables -t nat -X KOOLPROXY_HTTPS > /dev/null 2>&1
    ipset -F black_koolproxy > /dev/null 2>&1 && ipset -X black_koolproxy > /dev/null 2>&1
    ipset -F white_kp_list > /dev/null 2>&1 && ipset -X white_kp_list > /dev/null 2>&1
}

lan_acess_control () {
    [ ! -f $CONF ] && touch $CONF
    cat $CONF | while read line
    do
        mac=$(echo $line | cut -d',' -f2)
        proxy_name=$(echo $line | cut -d',' -f1)
        proxy_mode=$(echo $line | cut -d',' -f3)
        logsh "【$service】" "加载ACL规则:【$proxy_name】模式为:$(get_mode_name $proxy_mode)"
        iptables -t nat -A KOOLPROXY $(factor $mac "-m mac --mac-source") -p tcp $(get_jump_mode $proxy_mode) $(get_action_chain $proxy_mode)
    done
    koolproxy_acl_default_mode=$(uci -q get monlor.$appname.koolproxy_acl_default_mode) || koolproxy_acl_default_mode=1
    logsh "【$service】" "加载ACL规则:其余主机模式为:$(get_mode_name $koolproxy_acl_default_mode)"
}

load_nat(){
    logsh "【$service】" "加载nat规则!"
    #----------------------BASIC RULES---------------------
    logsh "【$service】" "写入iptables规则到nat表中..."
    # 创建KOOLPROXY nat rule
    iptables -t nat -N KOOLPROXY
    # 局域网地址不走KP
    iptables -t nat -A KOOLPROXY -m set --match-set white_kp_list dst -j RETURN
    #  生成对应CHAIN
    iptables -t nat -N KOOLPROXY_HTTP
    iptables -t nat -A KOOLPROXY_HTTP -p tcp -m multiport --dport 80,82,8080 -j REDIRECT --to-ports 3000
    iptables -t nat -N KOOLPROXY_HTTPS
    iptables -t nat -A KOOLPROXY_HTTPS -p tcp -m multiport --dport 80,82,443,8080 -j REDIRECT --to-ports 3000
    # 局域网控制
    lan_acess_control
    # 剩余流量转发到缺省规则定义的链中
    iptables -t nat -A KOOLPROXY -p tcp -j $(get_action_chain $koolproxy_acl_default_mode)
    # 重定所有流量到 KOOLPROXY
    # 全局模式和视频模式
    iptablenu=$(iptables -nvL PREROUTING -t nat | sed 1,2d | sed -n '/SHADOWSOCKS/=' | head -n1)
    if [ ! -z "$iptablenu" ];then
        let iptablenu=$iptablenu+1
    else
        iptablenu=2
    fi
    [ "$koolproxy_policy" == "1" ] || [ "$koolproxy_policy" == "3" ] && iptables -t nat -I PREROUTING $iptablenu -p tcp -j KOOLPROXY
    # ipset 黑名单模式
    [ "$koolproxy_policy" == "2" ] && iptables -t nat -I PREROUTING 2 -p tcp -m set --match-set black_koolproxy dst -j KOOLPROXY
}

dns_takeover () {
    lan_ipaddr=$(uci get network.lan.ipaddr)
    iptablenu=$(iptables -t nat -L PREROUTING -v -n --line-numbers|grep "dpt:53"|awk '{print $1}')
    if [ '$iptablenu' == '' ];then
        iptables -t nat -A PREROUTING -p udp --dport 53 -j DNAT --to $lan_ipaddr >/dev/null 2>&1
    fi
}

detect_cert () {

    if [ ! -f $monlorpath/apps/$appname/bin/data/private/ca.key.pem ]; then
        logsh "【$service】" "检测到首次运行，开始生成$appname证书，用于https过滤！"
        cd $monlorpath/apps/$appname/bin/data && sh gen_ca.sh        
    fi
    if [ ! -f /www/ca.crt ]; then
        cp $monlorpath/apps/$appname/bin/data/certs/ca.crt /www
    fi
}

start () {

    result=$(ps | grep $BIN | grep -v grep | wc -l)
    if [ "$result" != '0' ];then
        logsh "【$service】" "$appname已经在运行！"
        exit
    fi
    [ -z $koolproxy_policy ] && logsh "【$service】" "$appname未配置" && exit
    detect_cert
    start_koolproxy
    add_ipset_conf && restart_dnsmasq
    create_ipset
    add_white_black_ip
    load_nat
    dns_takeover
    logsh "【$service】" "启动$appname服务完成！"
    logsh "【$service】" "https模式请访问http://192.168.31.1/ca.crt下载证书"
}

stop () {

    remove_ipset_conf && restart_dnsmasq
    flush_nat
    logsh "【$service】" "关闭$appname主进程..."
    ps  | grep $BIN | grep -v grep | grep -v {koolproxy} | grep -v restart | awk '{print $1}' | xargs kill -9 > /dev/null 2>&1
	
}

restart () {

    stop
    sleep 1
    start

}

status() {

    result=$(ps | grep $BIN | grep -v grep | wc -l)
    if [ "$result" == '0' ]; then
        echo "未运行"
        echo "0"
    else
        case "$koolproxy_policy" in
            1) flag="全局模式" ;;
            2) flag="黑名单模式" ;;
            3) flag="视频模式" ;;
        esac
        rules=$monlorpath/apps/$appname/bin/data/rules/koolproxy.txt
        rulesdate=$(cat $rules | grep "update\[rules\]" | awk '{print$3" "$4}') > /dev/null 2>&1
        videodate=$(cat $rules | grep "update\[video\]" | awk '{print$3}') > /dev/null 2>&1
        [ -z "$rulesdate" ] && rulesdate="更新中"
        [ -z "$videodate" ] && videodate="更新中"
        kp_ver=$($monlorpath/apps/$appname/bin/$appname -v)
        echo "模式: $flag, 版本: $kp_ver, 规则: $rulesdate"
        echo "1"
    fi

}

backup() {

    mkdir -p $monlorbackup/$appname
    cp -rf $CONF $monlorbackup/$appname/$appname.conf
    cp -rf $monlorpath/apps/$appname/bin/data/private $monlorbackup/$appname > /dev/null 2>&1
    cp -rf $monlorpath/apps/$appname/bin/data/certs $monlorbackup/$appname > /dev/null 2>&1

}

recover() {

    cp -rf $monlorbackup/$appname/$appname.conf $CONF
    cp -rf $monlorbackup/$appname/private $monlorpath/apps/$appname/bin/data > /dev/null 2>&1
    cp -rf $monlorbackup/$appname/certs $monlorpath/apps/$appname/bin/data > /dev/null 2>&1

}