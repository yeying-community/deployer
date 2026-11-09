#!/bin/bash

# 默认长度为32
length=${1:-32}

# 生成随机字符串
openssl rand -base64 "$length"
