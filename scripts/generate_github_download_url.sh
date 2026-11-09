#!/bin/bash

github_to_raw() {
    local github_url="$1"
    
    # 添加 https:// 如果缺失
    if [[ ! "$github_url" =~ ^https?:// ]]; then
        github_url="https://$github_url"
    fi
    
    # 使用 sed 进行转换
    # 将 github.com/user/repo/blob/branch/path 转换为 raw.githubusercontent.com/user/repo/branch/path
    local raw_url=$(echo "$github_url" | sed -E 's|github\.com/([^/]+)/([^/]+)/(blob\|tree)/([^/]+)/(.+)|raw.githubusercontent.com/\1/\2/\4/\5|')
    
    # 检查是否转换成功
    if [[ "$raw_url" == *"raw.githubusercontent.com"* ]]; then
        echo "$raw_url"
    else
        echo "错误: 无效的 GitHub URL 格式" >&2
        return 1
    fi
}

# 主程序
main() {
    if [ $# -eq 0 ]; then
        echo "用法: $0 <github-url> [github-url2] ..."
        echo "示例: $0 'https://github.com/user/repo/blob/main/file.txt'"
        exit 1
    fi
    
    for url in "$@"; do
        echo "输入: $url"
        raw_url=$(github_to_raw "$url")
        if [ $? -eq 0 ]; then
            echo "输出: $raw_url"
        fi
        echo "---"
    done
}

# 如果直接运行脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

