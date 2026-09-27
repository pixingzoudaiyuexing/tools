#!/usr/bin/env bash

AI_CHECK_URL="https://raw.githubusercontent.com/adsorgcn/vpscheck/main/vpscheck.sh"

run_ai_check() {
    local temp_file status
    temp_file="$(mktemp)" || { error "无法创建临时文件。"; return 1; }

    if ! download_file "$AI_CHECK_URL" "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    info "即将启动第三方项目：adsorgcn/vpscheck（仅 AI 服务检测）"
    info "检测范围包括 ChatGPT / OpenAI API / Gemini / Claude / Copilot / Grok / Perplexity / DeepSeek / Kimi 等。"
    bash "$temp_file" -r 5
    status=$?
    rm -f "$temp_file"
    return "$status"
}

module_main() {
    title "AI 服务检测"
    run_ai_check
    local status=$?
    pause
    return "$status"
}
