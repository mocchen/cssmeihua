ddns
```
bash <(wget -qO- https://raw.githubusercontent.com/mocchen/cssmeihua/mochen/shell/ddns.sh)
```

Debian一键换源
```
bash <(wget -qO- https://raw.githubusercontent.com/mocchen/cssmeihua/mochen/shell/source.sh)
```

TCP调优 (参数比较暴力）
```
bash <(wget -qO- https://raw.githubusercontent.com/mocchen/cssmeihua/mochen/shell/optimize_fix.sh)
```

OpenSSL端口扫描脚本
```
wget https://raw.githubusercontent.com/mocchen/cssmeihua/refs/heads/mochen/shell/ssl.sh
```
用法
```
用法: ssl.sh <目标> [选项]
  
目标格式:
  域名: example.com
  单个IP: 192.168.1.1

选项:
  -p <端口>        指定端口 (如: 80-443 或 80,443,8080)
  -f <文件>        从文件读取端口列表
  -t <超时时间>    设置连接超时时间(秒)，默认: 3
  -j <线程数>      设置并发线程数，默认: 20
  -v               详细输出模式
  --check-cert     检查证书详细信息
  --rate-limit     启用速率限制(毫秒)，默认: 100
  --show-closed    显示关闭的端口
  --output <文件>  将结果保存到文件
  --http           开启http扫描
  --socks          开启socks扫描

示例:
  ssl.sh example.com -p 443 -j 50
  ssl.sh 192.168.1.1 -p 80,443,8443
  ```
