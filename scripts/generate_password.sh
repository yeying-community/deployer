#!/bin/bash

# 检查参数数量
if [ "$#" -ne 1 ]; then
    echo "用法: $0 <长度>"
    exit 1
fi

# 获取密码长度
length=$1

# 检查长度是否为正整数
if ! [[ "$length" =~ ^[1-9][0-9]*$ ]]; then
    echo "请输入一个有效的正整数作为密码长度"
    exit 1
fi

# 生成密码
password=$(LC_ALL=C < /dev/urandom tr -dc 'A-Za-z0-9!@#$%^&*()_+[]{}|;:,.<>?~' | head -c "$length")

# 输出生成的密码
echo "生成的密码: $password"

