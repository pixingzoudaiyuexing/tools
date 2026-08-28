#!/usr/bin/env bash

module_main() {
    title "流媒体 / 地区解锁检测"
    run_remote_bash "https://check.unlock.media" "lmc999/RegionRestrictionCheck"
    pause
}
