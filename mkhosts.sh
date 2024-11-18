#!/bin/bash
# 安装 ping3 包
pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple ping3
# 创建目录
mkdir -p /etc/hosts

# 下载文件
wget -P /etc/hosts "https://gitee.com/sonata1/code-snippet/raw/master/media_sever/mkhosts/mkhosts.py"

# 添加定时任务
{ crontab -l; echo "0 3 * * 5 /usr/bin/python3 /etc/hosts/mkhosts.py"; } | crontab -
echo "脚本执行完成，任务已设置。"
