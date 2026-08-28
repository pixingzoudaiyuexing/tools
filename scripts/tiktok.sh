#!/usr/bin/env bash

module_main() {
    title "TikTok 地区检测"
    run_remote_bash "https://raw.githubusercontent.com/lmc999/TikTokCheck/main/tiktok.sh" "lmc999/TikTokCheck"
    pause
}
