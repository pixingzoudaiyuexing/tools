#!/usr/bin/env bash

# Linux / 云服务器首次启动时间检查。
# 只读取本机状态和云厂商只读元数据，不修改系统或云实例配置。

server_birth_line() {
    printf '%s\n' '------------------------------------------------------------'
}

server_birth_section() {
    printf '\n'
    server_birth_line
    printf '%b%s%b\n' "$COLOR_BLUE" "$1" "$COLOR_RESET"
    server_birth_line
}

server_birth_value() {
    printf '%-28s %s\n' "$1" "$2"
}

server_birth_epoch_from_date() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    date -d "$value" '+%s' 2>/dev/null
}

server_birth_format_epoch() {
    local epoch="$1" zone="${2:-local}"
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    if [[ "$zone" == "beijing" ]]; then
        TZ=Asia/Shanghai date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S CST' 2>/dev/null
    else
        date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null
    fi
}

server_birth_show_epoch() {
    local label="$1" epoch="$2" local_time beijing
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 0
    local_time="$(server_birth_format_epoch "$epoch" local 2>/dev/null || true)"
    beijing="$(server_birth_format_epoch "$epoch" beijing 2>/dev/null || true)"
    [[ -n "$local_time" ]] && server_birth_value "$label" "$local_time"
    [[ -n "$beijing" ]] && server_birth_value "  北京时间:" "$beijing"
}

server_birth_abs_diff() {
    local a="$1" b="$2"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
    if ((a >= b)); then
        printf '%s\n' "$((a - b))"
    else
        printf '%s\n' "$((b - a))"
    fi
}

server_birth_journal_conflicts_with_boot() {
    local boot_epoch="$1" journal_epoch="$2"
    [[ "$boot_epoch" =~ ^[0-9]+$ && "$journal_epoch" =~ ^[0-9]+$ ]] || return 1
    ((journal_epoch > boot_epoch + 60))
}

server_birth_stat_birth_epoch() {
    local path="$1" epoch
    [[ -e "$path" ]] || return 1
    epoch="$(stat -c '%W' "$path" 2>/dev/null || true)"
    [[ "$epoch" =~ ^[0-9]+$ ]] && ((epoch > 0)) || return 1
    printf '%s\n' "$epoch"
}

server_birth_stat_mtime_epoch() {
    local path="$1" epoch
    [[ -e "$path" ]] || return 1
    epoch="$(stat -c '%Y' "$path" 2>/dev/null || true)"
    [[ "$epoch" =~ ^[0-9]+$ ]] && ((epoch > 0)) || return 1
    printf '%s\n' "$epoch"
}

server_birth_oldest_file_epoch() {
    local path epoch oldest=""
    for path in "$@"; do
        [[ -e "$path" ]] || continue
        epoch="$(server_birth_stat_birth_epoch "$path" 2>/dev/null || server_birth_stat_mtime_epoch "$path" 2>/dev/null || true)"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        if [[ -z "$oldest" ]] || ((epoch < oldest)); then
            oldest="$epoch"
        fi
    done
    [[ -n "$oldest" ]] && printf '%s\n' "$oldest"
}

server_birth_oldest_dir_mtime() {
    local dir="$1" path epoch oldest=""
    [[ -d "$dir" ]] || return 1
    for path in "$dir"/*; do
        [[ -e "$path" ]] || continue
        epoch="$(server_birth_stat_mtime_epoch "$path" 2>/dev/null || true)"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        if [[ -z "$oldest" ]] || ((epoch < oldest)); then
            oldest="$epoch"
        fi
    done
    [[ -n "$oldest" ]] && printf '%s\n' "$oldest"
}

server_birth_cloud_log_first_line() {
    local file
    {
        for file in /var/log/cloud-init.log /var/log/cloud-init.log.[0-9]* /var/log/cloud-init.log-*.gz /var/log/cloud-init.log.*.gz; do
            [[ -e "$file" ]] || continue
            case "$file" in
                *.gz)
                    command_exists zgrep && zgrep -h 'Cloud-init v' "$file" 2>/dev/null || true
                    ;;
                *)
                    grep 'Cloud-init v' "$file" 2>/dev/null || true
                    ;;
            esac
        done
    } | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}' | LC_ALL=C sort | sed -n '1p'
}

server_birth_cloud_log_epoch() {
    local line="$1" stamp
    stamp="$(printf '%s\n' "$line" | sed -n 's/^\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}[ T][0-9:]\{8\}\).*/\1/p')"
    [[ -n "$stamp" ]] || return 1
    server_birth_epoch_from_date "${stamp} UTC"
}

server_birth_journal_first_epoch() {
    local epoch
    command_exists journalctl || return 1
    epoch="$(journalctl --no-pager -o short-unix 2>/dev/null \
        | sed -n 's/^\([0-9][0-9]*\)\.[0-9][0-9]* .*/\1/p' \
        | sed -n '1p' || true)"
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$epoch"
}

server_birth_wtmp_begins_epoch() {
    local file="$1" line value
    [[ -f "$file" ]] || return 1
    line="$(LC_ALL=C last -F -f "$file" 2>/dev/null | grep 'wtmp begins' | tail -1 || true)"
    value="${line#*wtmp begins }"
    [[ -n "$value" && "$value" != "$line" ]] || return 1
    server_birth_epoch_from_date "$value"
}

server_birth_wtmp_oldest_epoch() {
    local file epoch oldest=""
    command_exists last || return 1
    for file in /var/log/wtmp /var/log/wtmp.1 /var/log/wtmp-[0-9]*; do
        [[ -f "$file" ]] || continue
        epoch="$(server_birth_wtmp_begins_epoch "$file" 2>/dev/null || true)"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        if [[ -z "$oldest" ]] || ((epoch < oldest)); then
            oldest="$epoch"
        fi
    done
    [[ -n "$oldest" ]] && printf '%s\n' "$oldest"
}

server_birth_dpkg_first_epoch() {
    local file line stamp
    {
        for file in /var/log/dpkg.log /var/log/dpkg.log.[0-9]* /var/log/dpkg.log-*.gz /var/log/dpkg.log.*.gz; do
            [[ -e "$file" ]] || continue
            case "$file" in
                *.gz)
                    command_exists zcat && zcat "$file" 2>/dev/null || true
                    ;;
                *)
                    cat "$file" 2>/dev/null || true
                    ;;
            esac
        done
    } | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' \
        | LC_ALL=C sort | sed -n '1p' | {
            IFS= read -r line || true
            stamp="$(printf '%s\n' "$line" | awk '{print $1 " " $2}')"
            [[ -n "$stamp" ]] && server_birth_epoch_from_date "$stamp" || true
        }
}

server_birth_detect_cloud() {
    local cloud="" datasource="" dmi="" lower

    if command_exists cloud-init; then
        cloud="$(cloud-init query v1.cloud_name 2>/dev/null || true)"
    fi

    if [[ -z "$cloud" && -f /var/lib/cloud/data/datasource ]]; then
        datasource="$(cat /var/lib/cloud/data/datasource 2>/dev/null || true)"
        lower="$(printf '%s' "$datasource" | tr '[:upper:]' '[:lower:]')"
        case "$lower" in
            *aliyun*) cloud="aliyun" ;;
            *ec2*) cloud="aws" ;;
            *azure*) cloud="azure" ;;
            *gce*|*google*) cloud="gcp" ;;
            *oracle*) cloud="oci" ;;
            *digitalocean*) cloud="digitalocean" ;;
            *openstack*) cloud="openstack" ;;
            *hetzner*) cloud="hetzner" ;;
            *scaleway*) cloud="scaleway" ;;
        esac
    fi

    if [[ -z "$cloud" ]]; then
        dmi="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ' || true)"
        lower="$(printf '%s' "$dmi" | tr '[:upper:]' '[:lower:]')"
        case "$lower" in
            *amazon*ec2*) cloud="aws" ;;
            *google*) cloud="gcp" ;;
            *microsoft*|*azure*) cloud="azure" ;;
            *alibaba*) cloud="aliyun" ;;
            *oraclecloud*|*oracle\ cloud*) cloud="oci" ;;
            *digitalocean*) cloud="digitalocean" ;;
            *hetzner*) cloud="hetzner" ;;
        esac
    fi

    printf '%s\n' "${cloud:-unknown}"
}

server_birth_cloud_display_name() {
    case "$1" in
        aws) printf 'Amazon EC2\n' ;;
        oci) printf 'Oracle Cloud OCI\n' ;;
        azure) printf 'Microsoft Azure\n' ;;
        gcp) printf 'Google Cloud Compute Engine\n' ;;
        aliyun) printf '阿里云 ECS\n' ;;
        tencent) printf '腾讯云 CVM\n' ;;
        digitalocean) printf 'DigitalOcean\n' ;;
        hetzner) printf 'Hetzner Cloud\n' ;;
        scaleway) printf 'Scaleway\n' ;;
        openstack) printf 'OpenStack\n' ;;
        *) printf '未明确识别\n' ;;
    esac
}

server_birth_curl_metadata() {
    curl -fsS --noproxy '*' --connect-timeout 1 --max-time 3 "$@" 2>/dev/null
}

SERVER_BIRTH_PROVIDER_KIND=""
SERVER_BIRTH_PROVIDER_TIME=""
SERVER_BIRTH_PROVIDER_NOTE=""
SERVER_BIRTH_PROVIDER_ID=""

server_birth_probe_provider_metadata() {
    local cloud="$1" token doc value raw ms
    SERVER_BIRTH_PROVIDER_KIND=""
    SERVER_BIRTH_PROVIDER_TIME=""
    SERVER_BIRTH_PROVIDER_NOTE=""
    SERVER_BIRTH_PROVIDER_ID=""

    command_exists curl || {
        SERVER_BIRTH_PROVIDER_NOTE="缺少 curl，未查询云厂商实例 Metadata。"
        return 0
    }

    case "$cloud" in
        aws)
            token="$(server_birth_curl_metadata -X PUT \
                -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
                http://169.254.169.254/latest/api/token || true)"
            if [[ -n "$token" ]]; then
                doc="$(server_birth_curl_metadata \
                    -H "X-aws-ec2-metadata-token: $token" \
                    http://169.254.169.254/latest/dynamic/instance-identity/document || true)"
                value="$(printf '%s\n' "$doc" | sed -n 's/.*"pendingTime"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
                SERVER_BIRTH_PROVIDER_ID="$(printf '%s\n' "$doc" | sed -n 's/.*"instanceId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
                if [[ -n "$value" ]]; then
                    SERVER_BIRTH_PROVIDER_TIME="$(server_birth_epoch_from_date "$value" 2>/dev/null || true)"
                    SERVER_BIRTH_PROVIDER_KIND="launch"
                    SERVER_BIRTH_PROVIDER_NOTE="AWS instance identity document 的 pendingTime；用于云平台 launch 时间参考，不强行解释为最初购买时间。"
                fi
            fi
            ;;
        oci)
            doc="$(server_birth_curl_metadata \
                -H 'Authorization: Bearer Oracle' \
                http://169.254.169.254/opc/v2/instance/ || true)"
            ms="$(printf '%s\n' "$doc" | sed -n 's/.*"timeCreated"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | sed -n '1p')"
            SERVER_BIRTH_PROVIDER_ID="$(printf '%s\n' "$doc" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
            if [[ "$ms" =~ ^[0-9]+$ ]]; then
                SERVER_BIRTH_PROVIDER_TIME="$((ms / 1000))"
                SERVER_BIRTH_PROVIDER_KIND="creation"
                SERVER_BIRTH_PROVIDER_NOTE="OCI 官方实例 Metadata 的 timeCreated；这是云实例创建时间的强证据。"
            fi
            ;;
        aliyun)
            token="$(server_birth_curl_metadata -X PUT \
                -H 'X-aliyun-ecs-metadata-token-ttl-seconds: 60' \
                http://100.100.100.200/latest/api/token || true)"
            if [[ -n "$token" ]]; then
                SERVER_BIRTH_PROVIDER_ID="$(server_birth_curl_metadata \
                    -H "X-aliyun-ecs-metadata-token: $token" \
                    http://100.100.100.200/latest/meta-data/instance-id || true)"
            fi
            SERVER_BIRTH_PROVIDER_NOTE="阿里云 ECS 实例 Metadata 可用于识别实例，但官方实例内部 Metadata 未提供可直接作为创建时间的字段。"
            ;;
        azure)
            raw="$(server_birth_curl_metadata -H 'Metadata: true' \
                'http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-02-01&format=text' || true)"
            SERVER_BIRTH_PROVIDER_ID="$raw"
            SERVER_BIRTH_PROVIDER_NOTE="Azure 普通 IMDS 可识别 VM，但不把 attested document 的生成时间冒充 VM 创建时间；VM resource timeCreated 属于 ARM API 字段。"
            ;;
        gcp)
            SERVER_BIRTH_PROVIDER_ID="$(server_birth_curl_metadata -H 'Metadata-Flavor: Google' \
                http://169.254.169.254/computeMetadata/v1/instance/id || true)"
            SERVER_BIRTH_PROVIDER_NOTE="GCP Metadata Server 可识别实例；本脚本不读取实例 Service Account token 去调用 Compute API，因此不强取 creationTimestamp。"
            ;;
        digitalocean)
            SERVER_BIRTH_PROVIDER_ID="$(server_birth_curl_metadata http://169.254.169.254/metadata/v1/id || true)"
            SERVER_BIRTH_PROVIDER_NOTE="DigitalOcean Droplet Metadata 可识别实例；created_at 位于账户 API，实例内部 Metadata 不直接提供，因此不伪造创建时间。"
            ;;
        hetzner)
            SERVER_BIRTH_PROVIDER_ID="$(server_birth_curl_metadata http://169.254.169.254/hetzner/v1/metadata/instance-id || true)"
            SERVER_BIRTH_PROVIDER_NOTE="Hetzner Server Metadata 可识别实例，但不直接提供创建时间。"
            ;;
        scaleway)
            if command_exists scw-metadata; then
                SERVER_BIRTH_PROVIDER_ID="$(scw-metadata ID 2>/dev/null || true)"
            fi
            SERVER_BIRTH_PROVIDER_NOTE="Scaleway Metadata 可识别实例；创建时间需要账户级 Instance API，本脚本不读取用户 API 密钥。"
            ;;
        openstack)
            doc="$(server_birth_curl_metadata http://169.254.169.254/openstack/latest/meta_data.json || true)"
            SERVER_BIRTH_PROVIDER_ID="$(printf '%s\n' "$doc" | sed -n 's/.*"uuid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
            SERVER_BIRTH_PROVIDER_NOTE="OpenStack metadata 可识别实例；标准 meta_data.json 不提供通用实例创建时间字段。"
            ;;
        *)
            SERVER_BIRTH_PROVIDER_NOTE="未明确识别云厂商，不主动遍历带凭据的云 API。"
            ;;
    esac
}

server_birth_guest_agent_epoch() {
    local paths=(
        /var/log/waagent.log
        /var/log/google-guest-agent.log
        /var/log/google-startup-scripts.log
        /var/log/amazon/ssm/amazon-ssm-agent.log
        /var/log/aliyun-service.log
    )
    server_birth_oldest_file_epoch "${paths[@]}"
}

server_birth_run() {
    local hostname_now os kernel timezone dmi_vendor dmi_product cloud cloud_name
    local current_boot current_boot_epoch=""
    local journal_epoch="" journal_conflict=0 wtmp_epoch=""
    local root_dev root_fs fs_created="" fs_created_epoch=""
    local cloud_first_line="" cloud_log_epoch="" cloud_instance_id="" previous_instance_id="" datasource=""
    local cloud_instance_dir="" cloud_dir_birth_epoch="" cloud_sem_epoch="" cloud_boot_finished_epoch=""
    local machine_birth_epoch="" ssh_epoch="" installer_epoch="" dpkg_epoch="" guest_agent_epoch=""
    local weak_cluster=0 diff result_kind="none" result_epoch="" result_confidence=""

    title "Linux 云服务器首次启动时间检测"
    info "只读取系统信息和云厂商只读 Metadata，不修改任何配置。"
    info "结论会交叉校验时间关系；日志比当前启动还晚时会自动判定为已轮转 / 已清理。"

    server_birth_section "1. 基础信息"
    hostname_now="$(hostname 2>/dev/null || printf '未知')"
    os="$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
    kernel="$(uname -r 2>/dev/null || printf '未知')"
    timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    dmi_vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
    dmi_product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"

    server_birth_value "主机名:" "$hostname_now"
    server_birth_value "系统:" "${os:-未知}"
    server_birth_value "内核:" "$kernel"
    server_birth_value "系统时区:" "${timezone:-未知}"
    server_birth_value "DMI 厂商:" "${dmi_vendor:-未知}"
    server_birth_value "DMI 产品:" "${dmi_product:-未知}"

    server_birth_section "2. 当前这次启动时间（确定事实）"
    current_boot="$(uptime -s 2>/dev/null || true)"
    current_boot_epoch="$(awk '$1 == "btime" {print $2; exit}' /proc/stat 2>/dev/null || true)"
    if [[ "$current_boot_epoch" =~ ^[0-9]+$ ]]; then
        server_birth_show_epoch "当前启动:" "$current_boot_epoch"
    elif [[ -n "$current_boot" ]]; then
        server_birth_value "当前启动时间:" "$current_boot"
        current_boot_epoch="$(server_birth_epoch_from_date "$current_boot" 2>/dev/null || true)"
        [[ "$current_boot_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "转换后:" "$current_boot_epoch"
    else
        printf '无法获取当前启动时间。\n'
    fi
    printf '\n'
    uptime -p 2>/dev/null || true
    command_exists who && who -b 2>/dev/null || true

    server_birth_section "3. 云厂商识别 / 官方实例 Metadata"
    cloud="$(server_birth_detect_cloud)"
    cloud_name="$(server_birth_cloud_display_name "$cloud")"
    server_birth_value "识别结果:" "$cloud_name"
    [[ -f /var/lib/cloud/data/datasource ]] && datasource="$(cat /var/lib/cloud/data/datasource 2>/dev/null || true)"
    [[ -n "$datasource" ]] && server_birth_value "cloud-init datasource:" "$datasource"

    server_birth_probe_provider_metadata "$cloud"
    [[ -n "$SERVER_BIRTH_PROVIDER_ID" ]] && server_birth_value "云实例 ID:" "$SERVER_BIRTH_PROVIDER_ID"
    if [[ "$SERVER_BIRTH_PROVIDER_TIME" =~ ^[0-9]+$ ]]; then
        case "$SERVER_BIRTH_PROVIDER_KIND" in
            creation) server_birth_show_epoch "云厂商创建时间:" "$SERVER_BIRTH_PROVIDER_TIME" ;;
            launch) server_birth_show_epoch "云厂商 launch 时间:" "$SERVER_BIRTH_PROVIDER_TIME" ;;
        esac
    fi
    [[ -n "$SERVER_BIRTH_PROVIDER_NOTE" ]] && printf '\n%s\n' "$SERVER_BIRTH_PROVIDER_NOTE"

    server_birth_section "4. Cloud-init 当前实例状态"
    cloud_instance_id="$(cat /var/lib/cloud/data/instance-id 2>/dev/null || true)"
    previous_instance_id="$(cat /var/lib/cloud/data/previous-instance-id 2>/dev/null || true)"
    server_birth_value "当前 Instance ID:" "${cloud_instance_id:-未找到}"
    server_birth_value "上一个 Instance ID:" "${previous_instance_id:-未找到}"

    if [[ -L /var/lib/cloud/instance || -d /var/lib/cloud/instance ]]; then
        cloud_instance_dir="$(readlink -f /var/lib/cloud/instance 2>/dev/null || true)"
        server_birth_value "当前实例缓存目录:" "${cloud_instance_dir:-未知}"
    fi

    if [[ -n "$cloud_instance_dir" && -d "$cloud_instance_dir" ]]; then
        cloud_dir_birth_epoch="$(server_birth_stat_birth_epoch "$cloud_instance_dir" 2>/dev/null || true)"
        [[ "$cloud_dir_birth_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "实例缓存目录 Birth:" "$cloud_dir_birth_epoch"

        cloud_sem_epoch="$(server_birth_oldest_dir_mtime "$cloud_instance_dir/sem" 2>/dev/null || true)"
        [[ "$cloud_sem_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "最早 per-instance 信号:" "$cloud_sem_epoch"

        if [[ -f "$cloud_instance_dir/boot-finished" ]]; then
            cloud_boot_finished_epoch="$(server_birth_stat_mtime_epoch "$cloud_instance_dir/boot-finished" 2>/dev/null || true)"
            [[ "$cloud_boot_finished_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "最近 cloud-init 完成:" "$cloud_boot_finished_epoch"
            printf '说明：boot-finished 会随后续启动更新，不把它单独当作首次启动。\n'
        fi
    else
        printf '没有可用的 /var/lib/cloud/instance 当前实例缓存。\n'
    fi

    server_birth_section "5. Cloud-init 历史日志（含轮转日志）"
    cloud_first_line="$(server_birth_cloud_log_first_line 2>/dev/null || true)"
    if [[ -n "$cloud_first_line" ]]; then
        printf '%s\n' "$cloud_first_line"
        cloud_log_epoch="$(server_birth_cloud_log_epoch "$cloud_first_line" 2>/dev/null || true)"
        [[ "$cloud_log_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "最早 Cloud-init 日志:" "$cloud_log_epoch"
    else
        printf '当前及轮转的 cloud-init.log 中都没有找到 Cloud-init v 启动记录。\n'
    fi

    server_birth_section "6. systemd Journal 启动历史"
    if command_exists journalctl; then
        journalctl --list-boots --no-pager 2>/dev/null || printf '没有可用的 Journal 启动历史。\n'
        journal_epoch="$(server_birth_journal_first_epoch 2>/dev/null || true)"
        if [[ "$journal_epoch" =~ ^[0-9]+$ ]]; then
            printf '\n'
            server_birth_show_epoch "最早保留 Journal:" "$journal_epoch"
            if server_birth_journal_conflicts_with_boot "$current_boot_epoch" "$journal_epoch"; then
                journal_conflict=1
                printf '%b异常：最早保留 Journal 比当前这次启动还晚。%b\n' "$COLOR_YELLOW" "$COLOR_RESET"
                printf '这说明 Journal 已被轮转、清理或持久化日志是后来才启用的。\n'
                printf '该时间禁止参与“首次启动时间”估算。\n'
            else
                printf '说明：这里只代表“目前仍保留的最早 Journal”，不等于首次开机。\n'
            fi
        fi
    else
        printf '系统没有 journalctl。\n'
    fi

    server_birth_section "7. wtmp / reboot 历史（含 wtmp.1）"
    if command_exists last; then
        last -x reboot -F 2>/dev/null | tail -20 || true
        if [[ -f /var/log/wtmp.1 ]]; then
            printf '\n[wtmp.1]\n'
            last -x reboot -F -f /var/log/wtmp.1 2>/dev/null | tail -10 || true
        fi
        wtmp_epoch="$(server_birth_wtmp_oldest_epoch 2>/dev/null || true)"
        [[ "$wtmp_epoch" =~ ^[0-9]+$ ]] && {
            printf '\n'
            server_birth_show_epoch "最早保留 wtmp:" "$wtmp_epoch"
        }
        printf '说明：wtmp 也会轮转，只作为保留历史边界，不单独判定首次开机。\n'
    else
        printf '没有 last 命令。\n'
    fi

    server_birth_section "8. 根文件系统创建时间"
    root_dev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    root_fs="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
    server_birth_value "根分区:" "${root_dev:-未知}"
    server_birth_value "文件系统:" "${root_fs:-未知}"

    if [[ "$root_fs" == "ext4" || "$root_fs" == "ext3" || "$root_fs" == "ext2" ]]; then
        if command_exists tune2fs && [[ -n "$root_dev" ]]; then
            fs_created="$(tune2fs -l "$root_dev" 2>/dev/null | grep 'Filesystem created:' | sed 's/Filesystem created:[[:space:]]*//' || true)"
            if [[ -n "$fs_created" ]]; then
                server_birth_value "Filesystem created:" "$fs_created"
                fs_created_epoch="$(server_birth_epoch_from_date "$fs_created" 2>/dev/null || true)"
                [[ "$fs_created_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "文件系统创建转换:" "$fs_created_epoch"
            else
                printf '未获取到文件系统创建时间。\n'
            fi
        else
            printf '没有 tune2fs 或无法识别根分区。\n'
        fi
    else
        printf '当前根文件系统不是 ext2/ext3/ext4，跳过 tune2fs。\n'
    fi
    printf '说明：文件系统创建时间可能属于基础镜像 / 快照，不能单独代表当前云实例创建时间。\n'

    server_birth_section "9. machine-id / SSH Host Key"
    if [[ -f /etc/machine-id ]]; then
        machine_birth_epoch="$(server_birth_stat_birth_epoch /etc/machine-id 2>/dev/null || server_birth_stat_mtime_epoch /etc/machine-id 2>/dev/null || true)"
        [[ "$machine_birth_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "machine-id 最早时间:" "$machine_birth_epoch"
        stat /etc/machine-id 2>/dev/null | grep -E 'Birth:|Modify:|Change:' || true
    else
        printf '没有 /etc/machine-id\n'
    fi

    ssh_epoch="$(server_birth_oldest_file_epoch /etc/ssh/ssh_host_*_key 2>/dev/null || true)"
    if [[ "$ssh_epoch" =~ ^[0-9]+$ ]]; then
        printf '\n'
        server_birth_show_epoch "最早 SSH Host Key:" "$ssh_epoch"
    else
        printf '\n没有找到可用 SSH Host Key 时间。\n'
    fi
    printf '说明：machine-id / SSH Host Key 可能来自镜像；若云初始化时重新生成，则会成为更有价值的辅助证据。\n'

    server_birth_section "10. 系统安装 / 软件包历史"
    installer_epoch="$(server_birth_oldest_file_epoch /var/log/installer/* 2>/dev/null || true)"
    if [[ "$installer_epoch" =~ ^[0-9]+$ ]]; then
        server_birth_show_epoch "最早 installer 文件:" "$installer_epoch"
    else
        printf '没有找到 /var/log/installer 可用时间。\n'
    fi

    dpkg_epoch="$(server_birth_dpkg_first_epoch 2>/dev/null || true)"
    if [[ "$dpkg_epoch" =~ ^[0-9]+$ ]]; then
        server_birth_show_epoch "最早 dpkg 日志:" "$dpkg_epoch"
    else
        printf '没有找到可解析的 dpkg 历史。\n'
    fi
    printf '说明：这些主要反映系统 / 镜像制作历史，不作为云实例创建时间的独立证据。\n'

    server_birth_section "11. 云 Guest Agent 辅助记录"
    for path in \
        /var/log/waagent.log \
        /var/log/google-guest-agent.log \
        /var/log/google-startup-scripts.log \
        /var/log/amazon/ssm/amazon-ssm-agent.log \
        /var/log/aliyun-service.log; do
        [[ -e "$path" ]] || continue
        epoch="$(server_birth_stat_birth_epoch "$path" 2>/dev/null || server_birth_stat_mtime_epoch "$path" 2>/dev/null || true)"
        if [[ "$epoch" =~ ^[0-9]+$ ]]; then
            server_birth_show_epoch "$(basename "$path"):" "$epoch"
        fi
    done
    guest_agent_epoch="$(server_birth_guest_agent_epoch 2>/dev/null || true)"
    [[ "$guest_agent_epoch" =~ ^[0-9]+$ ]] || printf '没有找到已知云 Guest Agent 日志时间。\n'
    printf '说明：Agent 可能后装、升级或日志轮转，因此只作为辅助。\n'

    server_birth_section "12. 时间关系交叉校验"
    [[ "$current_boot_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "当前启动（确定）:" "$current_boot_epoch"
    [[ "$SERVER_BIRTH_PROVIDER_TIME" =~ ^[0-9]+$ ]] && {
        case "$SERVER_BIRTH_PROVIDER_KIND" in
            creation) server_birth_show_epoch "云厂商创建（强）:" "$SERVER_BIRTH_PROVIDER_TIME" ;;
            launch) server_birth_show_epoch "云厂商 launch（强）:" "$SERVER_BIRTH_PROVIDER_TIME" ;;
        esac
    }
    [[ "$cloud_sem_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "Cloud-init per-instance:" "$cloud_sem_epoch"
    [[ "$cloud_log_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "Cloud-init 最早日志:" "$cloud_log_epoch"
    [[ "$journal_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "Journal 最早保留:" "$journal_epoch"
    [[ "$wtmp_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "wtmp 最早保留:" "$wtmp_epoch"
    [[ "$fs_created_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "文件系统创建（弱）:" "$fs_created_epoch"
    [[ "$machine_birth_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "machine-id（弱）:" "$machine_birth_epoch"
    [[ "$ssh_epoch" =~ ^[0-9]+$ ]] && server_birth_show_epoch "SSH Host Key（弱）:" "$ssh_epoch"

    printf '\n[一致性检查]\n'
    if ((journal_conflict == 1)); then
        printf '%b- Journal 与当前启动时间矛盾：Journal 已截断，排除。%b\n' "$COLOR_YELLOW" "$COLOR_RESET"
    elif [[ "$journal_epoch" =~ ^[0-9]+$ ]]; then
        printf -- '- Journal 时间关系没有直接矛盾，但仍只代表“最早保留日志”。\n'
    fi

    if [[ "$cloud_sem_epoch" =~ ^[0-9]+$ && "$cloud_log_epoch" =~ ^[0-9]+$ ]]; then
        diff="$(server_birth_abs_diff "$cloud_sem_epoch" "$cloud_log_epoch")"
        if ((diff <= 86400)); then
            printf '%b- Cloud-init per-instance 与最早日志在 24 小时内，互相支持。%b\n' "$COLOR_GREEN" "$COLOR_RESET"
        else
            printf '%b- Cloud-init 缓存与日志相差超过 24 小时，可能发生日志清理、缓存继承或镜像克隆。%b\n' "$COLOR_YELLOW" "$COLOR_RESET"
        fi
    fi

    if [[ "$fs_created_epoch" =~ ^[0-9]+$ && "$machine_birth_epoch" =~ ^[0-9]+$ ]]; then
        diff="$(server_birth_abs_diff "$fs_created_epoch" "$machine_birth_epoch")"
        if ((diff <= 3600)); then
            weak_cluster=$((weak_cluster + 1))
            printf '%b- 文件系统与 machine-id 在 1 小时内：支持“系统镜像 / OS 初始化时间”线索。%b\n' "$COLOR_GREEN" "$COLOR_RESET"
        fi
    fi
    if [[ "$machine_birth_epoch" =~ ^[0-9]+$ && "$ssh_epoch" =~ ^[0-9]+$ ]]; then
        diff="$(server_birth_abs_diff "$machine_birth_epoch" "$ssh_epoch")"
        if ((diff <= 3600)); then
            weak_cluster=$((weak_cluster + 1))
            printf '%b- machine-id 与 SSH Host Key 在 1 小时内：系统初始化线索进一步吻合。%b\n' "$COLOR_GREEN" "$COLOR_RESET"
        fi
    fi

    server_birth_section "13. 综合判断"

    if [[ "$SERVER_BIRTH_PROVIDER_KIND" == "creation" && "$SERVER_BIRTH_PROVIDER_TIME" =~ ^[0-9]+$ ]]; then
        result_kind="cloud-creation"
        result_epoch="$SERVER_BIRTH_PROVIDER_TIME"
        result_confidence="高"
    elif [[ "$cloud_sem_epoch" =~ ^[0-9]+$ ]]; then
        result_kind="cloud-init-instance"
        result_epoch="$cloud_sem_epoch"
        result_confidence="中高"
        if [[ "$cloud_log_epoch" =~ ^[0-9]+$ ]]; then
            diff="$(server_birth_abs_diff "$cloud_sem_epoch" "$cloud_log_epoch")"
            ((diff <= 86400)) || result_confidence="中"
        fi
    elif [[ "$cloud_log_epoch" =~ ^[0-9]+$ ]]; then
        result_kind="cloud-init-log"
        result_epoch="$cloud_log_epoch"
        result_confidence="中"
    fi

    case "$result_kind" in
        cloud-creation)
            printf '%b可直接获得较强的云实例创建时间证据：%b\n\n' "$COLOR_GREEN" "$COLOR_RESET"
            server_birth_show_epoch "最可能云实例创建:" "$result_epoch"
            printf '可信度：%s\n' "$result_confidence"
            printf '依据：云厂商官方实例 Metadata 的创建时间字段。\n'
            ;;
        cloud-init-instance)
            printf '%b没有云厂商直接创建时间，但找到当前实例的 Cloud-init per-instance 首次运行线索。%b\n\n' "$COLOR_YELLOW" "$COLOR_RESET"
            server_birth_show_epoch "当前实例初始化候选:" "$result_epoch"
            printf '可信度：%s\n' "$result_confidence"
            printf '注意：如果系统盘来自未清理 cloud-init 缓存的快照 / 克隆镜像，该时间仍可能继承。\n'
            ;;
        cloud-init-log)
            printf '%b只能从 Cloud-init 最早保留日志得到初始化候选。%b\n\n' "$COLOR_YELLOW" "$COLOR_RESET"
            server_birth_show_epoch "Cloud-init 初始化候选:" "$result_epoch"
            printf '可信度：%s\n' "$result_confidence"
            printf '注意：日志可能轮转，不能证明它就是绝对第一次开机。\n'
            ;;
        *)
            printf '%b无法可靠确定“当前云实例第一次创建 / 第一次开机”的精确时间。%b\n\n' "$COLOR_YELLOW" "$COLOR_RESET"
            if [[ "$current_boot_epoch" =~ ^[0-9]+$ ]]; then
                printf '可以确定的事实：\n'
                server_birth_show_epoch "当前这次启动始于:" "$current_boot_epoch"
                printf '因此当前实例 / 系统在这个时间点已经存在并运行。\n\n'
            fi
            if ((weak_cluster > 0)) && [[ "$machine_birth_epoch" =~ ^[0-9]+$ ]]; then
                printf '另外有多项弱证据互相吻合，可作为“系统镜像 / OS 初始化时间”参考：\n'
                server_birth_show_epoch "系统初始化线索:" "$machine_birth_epoch"
                printf '但这不能等同于云实例购买或创建时间。\n\n'
            fi
            if ((journal_conflict == 1)); then
                printf '%b最早 Journal 已明确晚于当前启动时间，所以它已被排除，不再给“中等可信度”的首次启动估算。%b\n' "$COLOR_YELLOW" "$COLOR_RESET"
            fi
            ;;
    esac

    if [[ "$SERVER_BIRTH_PROVIDER_KIND" == "launch" && "$SERVER_BIRTH_PROVIDER_TIME" =~ ^[0-9]+$ ]]; then
        printf '\n[云平台 launch 时间]\n'
        server_birth_show_epoch "AWS pendingTime:" "$SERVER_BIRTH_PROVIDER_TIME"
        printf '这是强的云平台 launch 事件证据，但和“实例最初创建 / 购买时间”不是同一个概念。\n'
    fi

    printf '\n'
    server_birth_line
    printf '检测完成。所有时间证据已按“云厂商强证据 / Cloud-init / 保留日志 / 镜像弱证据”分层。\n'
}

module_main() {
    server_birth_run
    pause
}
