#!/bin/bash
# ============================================================
# cluster-status.sh v2 - Status klastra Proxmox CLUSTER01
# ============================================================
# Formaty:
#   pretty (default) - kolorowy output do terminala
#   html             - self-contained HTML z exports (PDF/Excel/CSV)
#   json             - machine-readable (do dashboard)
#   csv              - Excel-friendly
#
# Wymagania:
#   pvesh (Proxmox VE - builtin) + jq (auto-install)
#
# Użycie:
#   ./cluster-status.sh
#   ./cluster-status.sh --format html
#   ./cluster-status.sh --format json
#   ./cluster-status.sh --format csv
#   ./cluster-status.sh --output file.html
#   ./cluster-status.sh -v
#   ./cluster-status.sh -h
#
# Repo: gitea.lan:3000/tomasz/proxmox-tools
# Wersja: 2.0
# ============================================================

set -u

VERBOSE=0
USE_COLOR=1
FORMAT="pretty"
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=1; shift ;;
        --no-color)   USE_COLOR=0; shift ;;
        --format)     FORMAT="$2"; shift 2 ;;
        --output|-o)  OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help)
            grep -E "^# " "$0" | head -28 | sed 's/^# //'
            exit 0
            ;;
        *) echo "Nieznany: $1" >&2; exit 1 ;;
    esac
done

case "$FORMAT" in
    pretty|html|json|csv) ;;
    *) echo "Niepoprawny format: $FORMAT" >&2; exit 1 ;;
esac

[[ "$FORMAT" != "pretty" ]] && USE_COLOR=0

# Kolory ANSI
if [[ $USE_COLOR -eq 1 ]] && [[ -t 1 ]] && [[ -z "$OUTPUT_FILE" ]]; then
    BOLD="\033[1m"; DIM="\033[2m"
    RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
    BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m"
    RESET="\033[0m"
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; RESET=""
fi

check_prereqs() {
    command -v pvesh &>/dev/null || { echo "BŁĄD: pvesh nie znaleziono" >&2; exit 1; }
    if ! command -v jq &>/dev/null; then
        echo "Instaluję jq..." >&2
        apt update -qq >/dev/null 2>&1
        apt install -y -qq jq >/dev/null 2>&1
        command -v jq &>/dev/null || { echo "BŁĄD: nie udało się jq" >&2; exit 1; }
    fi
}

# === FORMAT HELPERS ===
human_bytes() {
    local b=$1
    [[ -z "$b" || "$b" == "null" || "$b" -eq 0 ]] && { echo "0"; return; }
    awk -v b="$b" 'BEGIN {
        if (b >= 1099511627776) printf "%.1fT", b/1099511627776
        else if (b >= 1073741824) printf "%.1fG", b/1073741824
        else if (b >= 1048576) printf "%.1fM", b/1048576
        else if (b >= 1024) printf "%.1fK", b/1024
        else printf "%dB", b
    }'
}

format_percent_raw() {
    awk -v f="$1" 'BEGIN { printf "%.0f", f*100 }'
}

format_percent_color() {
    local pct
    pct=$(format_percent_raw "$1")
    if [[ $pct -ge 90 ]]; then echo -e "${RED}${pct}%${RESET}"
    elif [[ $pct -ge 75 ]]; then echo -e "${YELLOW}${pct}%${RESET}"
    else echo -e "${GREEN}${pct}%${RESET}"; fi
}

format_status_color() {
    case "$1" in
        running) echo -e "${GREEN}● running${RESET}" ;;
        stopped) echo -e "${DIM}○ stopped${RESET}" ;;
        *)       echo -e "${YELLOW}? $1${RESET}" ;;
    esac
}

detect_disk_type() {
    local devpath=$1 model=$2 vendor=$3
    local devname
    devname=$(basename "$devpath")
    [[ "$devname" == nvme* ]] && { echo "NVMe"; return; }
    if [[ "$model" == *"SSD"* || "$model" == *"EVO"* || "$model" == *"NVMe"* ]]; then
        echo "SSD"; return
    fi
    [[ "$model" == *"Expansion"* ]] && { echo "USB-HDD"; return; }
    echo "HDD"
}

csv_escape() {
    local v=$1
    if [[ "$v" == *","* || "$v" == *";"* || "$v" == *'"'* || "$v" == *$'\n'* ]]; then
        v="${v//\"/\"\"}"
        echo "\"$v\""
    else
        echo "$v"
    fi
}

html_escape() {
    local v=$1
    v="${v//&/&amp;}"; v="${v//</&lt;}"; v="${v//>/&gt;}"
    v="${v//\"/&quot;}"; v="${v//\'/&#39;}"
    echo "$v"
}

strip_ansi() {
    sed 's/\x1B\[[0-9;]*[mK]//g'
}

# === COLLECT DATA ===
collect_data() {
    local status_json
    status_json=$(pvesh get /cluster/status --output-format json 2>/dev/null)

    CLUSTER_NAME=$(echo "$status_json" | jq -r '.[] | select(.type == "cluster") | .name')
    CLUSTER_VERSION=$(echo "$status_json" | jq -r '.[] | select(.type == "cluster") | .version')
    CLUSTER_NODES=$(echo "$status_json" | jq -r '.[] | select(.type == "cluster") | .nodes')
    CLUSTER_QUORATE=$(echo "$status_json" | jq -r '.[] | select(.type == "cluster") | .quorate')

    NODES_JSON=$(echo "$status_json" | jq -c '[.[] | select(.type == "node")]')
    RESOURCES_JSON=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)
    NODE_NAMES=$(echo "$NODES_JSON" | jq -r '.[] | select(.online == 1) | .name' | sort)

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    TIMESTAMP_ISO=$(date -Iseconds)
}

# ============================================================
# PRETTY OUTPUT
# ============================================================
output_pretty() {
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║         CLUSTER STATUS REPORT                                    ║${RESET}"
    echo -e "${BOLD}${CYAN}║         ${TIMESTAMP}                                       ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    echo -e "${BOLD}▸ KLASTER${RESET}"
    echo -e "  Nazwa:        ${BOLD}${CLUSTER_NAME}${RESET}"
    echo -e "  Wersja conf:  ${CLUSTER_VERSION}"
    echo -e "  Node-y:       ${CLUSTER_NODES}"
    if [[ "$CLUSTER_QUORATE" == "1" ]]; then
        echo -e "  Quorum:       ${GREEN}✓ Quorate${RESET}"
    else
        echo -e "  Quorum:       ${RED}✗ NOT QUORATE${RESET}"
    fi
    echo ""

    echo -e "  ${BOLD}Node${RESET}      ${BOLD}IP${RESET}                ${BOLD}Status${RESET}"
    echo -e "  ─────────────────────────────────────────────"
    echo "$NODES_JSON" | jq -r '.[] | "\(.name)|\(.ip)|\(.online)|\(.local)"' \
    | while IFS='|' read -r name ip online local; do
        local sl="" ll=""
        [[ "$online" == "1" ]] && sl="${GREEN}✓ online${RESET}" || sl="${RED}✗ offline${RESET}"
        [[ "$local" == "1" ]] && ll=" ${DIM}(local)${RESET}"
        printf "  %-10s%-18s" "$name" "$ip"
        echo -e "${sl}${ll}"
    done
    echo ""

    for node in $NODE_NAMES; do
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════${RESET}"
        echo -e "${BOLD}${CYAN} NODE: ${node}${RESET}"
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════${RESET}"
        echo ""
        pretty_disks "$node"
        pretty_storage "$node"
        pretty_vms "$node"
        pretty_lxc "$node"
    done

    pretty_summary
}

pretty_disks() {
    local node=$1
    echo -e "${BOLD}${BLUE}▸ ${node} — Fizyczne dyski${RESET}"
    printf "  ${BOLD}%-10s%-32s%-9s%-9s%-10s%s${RESET}\n" "Device" "Model" "Typ" "Size" "FS" "Health"
    echo -e "  ──────────────────────────────────────────────────────────────────────────"

    local disks
    disks=$(pvesh get "/nodes/${node}/disks/list" --output-format json 2>/dev/null)
    if [[ -z "$disks" || "$disks" == "null" || "$disks" == "[]" ]]; then
        echo -e "  ${DIM}(brak danych)${RESET}"
        echo ""
        return
    fi

    echo "$disks" | jq -r '.[] | "\(.devpath)|\(.model // "?")|\(.size // 0)|\(.used // "?")|\(.health // "?")|\(.vendor // "")"' \
    | while IFS='|' read -r devpath model size used health vendor; do
        local devname size_h dt dt_color hc model_short fs_label
        devname=$(basename "$devpath")
        size_h=$(human_bytes "$size")
        [[ ${#model} -gt 28 ]] && model_short="${model:0:25}..." || model_short="$model"

        dt=$(detect_disk_type "$devpath" "$model" "$vendor")
        case "$dt" in
            NVMe)    dt_color="${MAGENTA}NVMe${RESET}   " ;;
            SSD)     dt_color="${GREEN}SSD${RESET}    " ;;
            HDD)     dt_color="${BLUE}HDD${RESET}    " ;;
            USB-HDD) dt_color="${YELLOW}USB-HDD${RESET}" ;;
        esac

        case "$health" in
            PASSED) hc="${GREEN}PASSED${RESET}" ;;
            FAILED) hc="${RED}FAILED${RESET}" ;;
            *)      hc="${DIM}?${RESET}" ;;
        esac

        fs_label="$used"
        [[ -z "$fs_label" || "$fs_label" == "?" ]] && fs_label="-"

        printf "  %-10s%-32s" "$devname" "$model_short"
        echo -ne "${dt_color}  "
        printf "%-9s%-10s" "$size_h" "$fs_label"
        echo -e "$hc"
    done
    echo ""
}

pretty_storage() {
    local node=$1
    echo -e "${BOLD}${MAGENTA}▸ ${node} — Storage Proxmox${RESET}"
    printf "  ${BOLD}%-22s%-9s%-9s%-9s%-9s%-7s%s${RESET}\n" "Name" "Type" "Total" "Used" "Avail" "%" "Status"
    echo -e "  ─────────────────────────────────────────────────────────────────────────────"

    local sj
    sj=$(pvesh get "/nodes/${node}/storage" --output-format json 2>/dev/null)

    echo "$sj" | jq -r '.[] | "\(.storage)|\(.type)|\(.total // 0)|\(.used // 0)|\(.avail // 0)|\(.used_fraction // 0)|\(.active // 0)|\(.enabled // 0)"' \
    | sort \
    | while IFS='|' read -r name type total used avail frac active enabled; do
        local th uh ah pct sl
        if [[ "$active" == "1" ]]; then
            sl="${GREEN}● active${RESET}"
            th=$(human_bytes "$total"); uh=$(human_bytes "$used"); ah=$(human_bytes "$avail")
            pct=$(format_percent_color "$frac")
        elif [[ "$enabled" == "0" ]]; then
            sl="${DIM}○ disabled${RESET}"
            th="-"; uh="-"; ah="-"; pct="-"
        else
            sl="${YELLOW}? inactive${RESET}"
            th="-"; uh="-"; ah="-"; pct="-"
        fi

        printf "  %-22s%-9s%-9s%-9s%-9s" "$name" "$type" "$th" "$uh" "$ah"
        local pct_plain
        pct_plain=$(echo -e "$pct" | strip_ansi)
        echo -ne "$pct"
        local pad=$((7 - ${#pct_plain}))
        printf "%${pad}s" ""
        echo -e "$sl"
    done
    echo ""
}

pretty_vms() {
    local node=$1
    echo -e "${BOLD}${GREEN}▸ ${node} — VM-ki KVM${RESET}"
    printf "  ${BOLD}%-6s%-25s%-15s%-7s%-9s%s${RESET}\n" "VMID" "Nazwa" "Status" "CPU" "RAM" "Disk(max)"
    echo -e "  ────────────────────────────────────────────────────────────────────"

    local vms
    vms=$(echo "$RESOURCES_JSON" | jq -r --arg n "$node" \
        '.[] | select(.type == "qemu" and .node == $n and (.template // 0) == 0) | "\(.vmid)|\(.name)|\(.status)|\(.maxcpu)|\(.maxmem)|\(.maxdisk)"' | sort -n)

    if [[ -z "$vms" ]]; then
        echo -e "  ${DIM}(brak VM-ek)${RESET}"
        echo ""
        return
    fi

    echo "$vms" | while IFS='|' read -r vmid name status cpu mem disk; do
        local mh dh ss
        mh=$(human_bytes "$mem"); dh=$(human_bytes "$disk")
        ss=$(format_status_color "$status")
        [[ ${#name} -gt 22 ]] && name="${name:0:19}..."

        local ss_plain pad
        ss_plain=$(echo -e "$ss" | strip_ansi)
        pad=$((15 - ${#ss_plain}))

        printf "  %-6s%-25s" "$vmid" "$name"
        echo -ne "$ss"
        printf "%${pad}s" ""
        printf "%-7s%-9s%s\n" "${cpu}c" "$mh" "$dh"
    done
    echo ""
}

pretty_lxc() {
    local node=$1
    echo -e "${BOLD}${YELLOW}▸ ${node} — Kontenery LXC${RESET}"
    printf "  ${BOLD}%-6s%-25s%-15s%-7s%-9s%s${RESET}\n" "CTID" "Nazwa" "Status" "CPU" "RAM" "Disk(max)"
    echo -e "  ────────────────────────────────────────────────────────────────────"

    local cts
    cts=$(echo "$RESOURCES_JSON" | jq -r --arg n "$node" \
        '.[] | select(.type == "lxc" and .node == $n) | "\(.vmid)|\(.name)|\(.status)|\(.maxcpu)|\(.maxmem)|\(.maxdisk)|\(.template // 0)"' | sort -n)

    if [[ -z "$cts" ]]; then
        echo -e "  ${DIM}(brak LXC)${RESET}"
        echo ""
        return
    fi

    echo "$cts" | while IFS='|' read -r ctid name status cpu mem disk tmpl; do
        local mh dh ss nl
        mh=$(human_bytes "$mem"); dh=$(human_bytes "$disk")
        ss=$(format_status_color "$status")
        [[ ${#name} -gt 22 ]] && name="${name:0:19}..."
        nl="$name"
        [[ "$tmpl" == "1" ]] && nl="${name} ${DIM}[template]${RESET}"

        local ss_plain ss_pad nl_plain nl_pad
        ss_plain=$(echo -e "$ss" | strip_ansi)
        ss_pad=$((15 - ${#ss_plain}))
        nl_plain=$(echo -e "$nl" | strip_ansi)
        nl_pad=$((25 - ${#nl_plain}))

        printf "  %-6s" "$ctid"
        echo -ne "$nl"
        printf "%${nl_pad}s" ""
        echo -ne "$ss"
        printf "%${ss_pad}s" ""
        printf "%-7s%-9s%s\n" "${cpu}c" "$mh" "$dh"
    done
    echo ""
}

pretty_summary() {
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}▸ PODSUMOWANIE${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════${RESET}"

    local tv rv sv tc rc sc tpl tmb tmh
    tv=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "qemu" and (.template // 0) == 0)] | length')
    rv=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "qemu" and (.template // 0) == 0 and .status == "running")] | length')
    sv=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "qemu" and (.template // 0) == 0 and .status == "stopped")] | length')
    tc=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "lxc" and (.template // 0) == 0)] | length')
    rc=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "lxc" and (.template // 0) == 0 and .status == "running")] | length')
    sc=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "lxc" and (.template // 0) == 0 and .status == "stopped")] | length')
    tpl=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "lxc" and .template == 1)] | length')
    tmb=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.status == "running") | .maxmem // 0] | add')
    tmh=$(human_bytes "$tmb")

    echo -e "  VM-ki KVM:    ${tv} (${GREEN}${rv} running${RESET}, ${DIM}${sv} stopped${RESET})"
    echo -e "  LXC:          ${tc} (${GREEN}${rc} running${RESET}, ${DIM}${sc} stopped${RESET})${DIM}, ${tpl} template${RESET}"
    echo -e "  RAM (running): ${tmh}"
    echo ""
}

# ============================================================
# JSON OUTPUT
# ============================================================
output_json() {
    local nodes_data="["
    local first=1
    for node in $NODE_NAMES; do
        [[ $first -eq 0 ]] && nodes_data+=","
        first=0
        local d s v l
        d=$(pvesh get "/nodes/${node}/disks/list" --output-format json 2>/dev/null)
        s=$(pvesh get "/nodes/${node}/storage" --output-format json 2>/dev/null)
        v=$(echo "$RESOURCES_JSON" | jq --arg n "$node" '[.[] | select(.type == "qemu" and .node == $n)]')
        l=$(echo "$RESOURCES_JSON" | jq --arg n "$node" '[.[] | select(.type == "lxc" and .node == $n)]')

        nodes_data+=$(jq -n \
            --arg name "$node" \
            --argjson disks "${d:-[]}" \
            --argjson storage "${s:-[]}" \
            --argjson vms "${v:-[]}" \
            --argjson lxc "${l:-[]}" \
            '{name: $name, disks: $disks, storage: $storage, vms: $vms, lxc: $lxc}')
    done
    nodes_data+="]"

    jq -n \
        --arg ts "$TIMESTAMP_ISO" \
        --arg cn "$CLUSTER_NAME" \
        --argjson cv "$CLUSTER_VERSION" \
        --argjson nc "$CLUSTER_NODES" \
        --argjson cq "$CLUSTER_QUORATE" \
        --argjson ni "$NODES_JSON" \
        --argjson nd "$nodes_data" \
        '{
            timestamp: $ts,
            cluster: {
                name: $cn,
                version: $cv,
                nodes_count: $nc,
                quorate: ($cq == 1),
                nodes_info: $ni
            },
            nodes: $nd
        }'
}

# ============================================================
# CSV OUTPUT
# ============================================================
output_csv() {
    printf '\xEF\xBB\xBF'  # BOM dla Excel

    echo "# Cluster info"
    echo "section,key,value"
    echo "cluster,name,$(csv_escape "$CLUSTER_NAME")"
    echo "cluster,version,$CLUSTER_VERSION"
    echo "cluster,nodes_count,$CLUSTER_NODES"
    echo "cluster,quorate,$CLUSTER_QUORATE"
    echo "cluster,timestamp,$(csv_escape "$TIMESTAMP")"
    echo ""

    echo "# Nodes"
    echo "section,name,ip,nodeid,online,local"
    echo "$NODES_JSON" | jq -r '.[] | "node,\(.name),\(.ip),\(.nodeid),\(.online),\(.local)"'
    echo ""

    echo "# Disks"
    echo "section,node,device,model,vendor,type,size_bytes,size_human,fs,health,serial"
    for node in $NODE_NAMES; do
        local d
        d=$(pvesh get "/nodes/${node}/disks/list" --output-format json 2>/dev/null)
        echo "$d" | jq -r --arg n "$node" '.[] | "\($n)|\(.devpath)|\(.model // "")|\(.vendor // "")|\(.size // 0)|\(.used // "")|\(.health // "")|\(.serial // "")"' \
        | while IFS='|' read -r n dp m v sz u h sr; do
            local sh dt
            sh=$(human_bytes "$sz")
            dt=$(detect_disk_type "$dp" "$m" "$v")
            echo "disk,$n,$(basename "$dp"),$(csv_escape "$m"),$(csv_escape "$v"),$dt,$sz,$sh,$(csv_escape "$u"),$h,$(csv_escape "$sr")"
        done
    done
    echo ""

    echo "# Storage"
    echo "section,node,name,type,total_bytes,used_bytes,avail_bytes,used_pct,active,enabled,content"
    for node in $NODE_NAMES; do
        local s
        s=$(pvesh get "/nodes/${node}/storage" --output-format json 2>/dev/null)
        echo "$s" | jq -r --arg n "$node" '.[] | "\($n)|\(.storage)|\(.type)|\(.total // 0)|\(.used // 0)|\(.avail // 0)|\(.used_fraction // 0)|\(.active // 0)|\(.enabled // 0)|\(.content // "")"' \
        | while IFS='|' read -r n nm tp t u a f ac en c; do
            local p
            p=$(format_percent_raw "$f")
            echo "storage,$n,$(csv_escape "$nm"),$tp,$t,$u,$a,$p,$ac,$en,$(csv_escape "$c")"
        done
    done
    echo ""

    echo "# VMs"
    echo "section,node,vmid,name,status,cpu,ram_bytes,disk_max_bytes"
    echo "$RESOURCES_JSON" | jq -r '.[] | select(.type == "qemu" and (.template // 0) == 0) | "vm,\(.node),\(.vmid),\(.name),\(.status),\(.maxcpu),\(.maxmem),\(.maxdisk)"'
    echo ""

    echo "# LXC"
    echo "section,node,ctid,name,status,cpu,ram_bytes,disk_max_bytes,template"
    echo "$RESOURCES_JSON" | jq -r '.[] | select(.type == "lxc") | "lxc,\(.node),\(.vmid),\(.name),\(.status),\(.maxcpu),\(.maxmem),\(.maxdisk),\(.template // 0)"'
}

# ============================================================
# HTML OUTPUT
# ============================================================
output_html() {
cat << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="pl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Cluster Status</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
       background: #f5f7fa; color: #2c3e50; padding: 20px; line-height: 1.5; }
.container { max-width: 1400px; margin: 0 auto; }
header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
         color: white; padding: 30px; border-radius: 12px; margin-bottom: 24px;
         box-shadow: 0 4px 6px rgba(0,0,0,0.1);
         display: flex; justify-content: space-between; align-items: center;
         flex-wrap: wrap; gap: 16px; }
header h1 { font-size: 28px; font-weight: 600; }
header .meta { font-size: 14px; opacity: 0.9; margin-top: 8px; }
.actions { display: flex; gap: 8px; flex-wrap: wrap; }
.actions button { background: rgba(255,255,255,0.2); border: 1px solid rgba(255,255,255,0.4);
                  color: white; padding: 8px 16px; border-radius: 6px; cursor: pointer;
                  font-size: 14px; font-weight: 500; transition: all 0.2s; }
.actions button:hover { background: rgba(255,255,255,0.35); transform: translateY(-1px); }
section { background: white; border-radius: 12px; padding: 24px; margin-bottom: 20px;
          box-shadow: 0 2px 4px rgba(0,0,0,0.05); }
h2 { font-size: 20px; color: #2c3e50; margin-bottom: 16px; padding-bottom: 8px;
     border-bottom: 2px solid #eef2f7; }
h3 { font-size: 16px; color: #34495e; margin: 20px 0 12px 0; }
.node-section { border-left: 4px solid #3498db; padding-left: 16px; }
.info-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
             gap: 12px; margin-bottom: 16px; }
.info-item { background: #f8f9fa; padding: 12px; border-radius: 6px; }
.info-item .label { font-size: 12px; color: #7f8c8d; text-transform: uppercase; letter-spacing: 0.5px; }
.info-item .value { font-size: 18px; font-weight: 600; color: #2c3e50; margin-top: 4px; }
table { width: 100%; border-collapse: collapse; margin: 12px 0; font-size: 14px; }
th { background: #f8f9fa; padding: 10px 12px; text-align: left; font-weight: 600;
     color: #34495e; border-bottom: 2px solid #dee2e6; cursor: pointer; user-select: none; position: relative; }
th:hover { background: #e9ecef; }
th::after { content: " ⇅"; opacity: 0.3; font-size: 10px; }
th.sorted-asc::after { content: " ↑"; opacity: 1; color: #3498db; }
th.sorted-desc::after { content: " ↓"; opacity: 1; color: #3498db; }
td { padding: 10px 12px; border-bottom: 1px solid #eef2f7; }
tr:hover { background: #f8f9fa; }
.badge { display: inline-block; padding: 3px 10px; border-radius: 12px;
         font-size: 12px; font-weight: 600; }
.badge-running { background: #d4edda; color: #155724; }
.badge-stopped { background: #e2e3e5; color: #6c757d; }
.badge-online { background: #d4edda; color: #155724; }
.badge-offline { background: #f8d7da; color: #721c24; }
.badge-active { background: #d1ecf1; color: #0c5460; }
.badge-disabled { background: #e2e3e5; color: #6c757d; }
.badge-template { background: #fff3cd; color: #856404; }
.badge-nvme { background: #e9d5ff; color: #6b21a8; }
.badge-ssd { background: #d4edda; color: #155724; }
.badge-hdd { background: #dbeafe; color: #1e40af; }
.badge-usb { background: #fef3c7; color: #92400e; }
.health-passed { color: #28a745; font-weight: 600; }
.health-failed { color: #dc3545; font-weight: 600; }
.health-unknown { color: #6c757d; }
.pct-bar { display: inline-block; width: 80px; height: 16px; background: #e9ecef;
           border-radius: 4px; overflow: hidden; vertical-align: middle; margin-right: 8px; }
.pct-fill { height: 100%; transition: width 0.3s; }
.pct-low { background: linear-gradient(90deg, #28a745, #20c997); }
.pct-med { background: linear-gradient(90deg, #ffc107, #fd7e14); }
.pct-high { background: linear-gradient(90deg, #dc3545, #c82333); }
.pct-text { display: inline-block; min-width: 40px; font-weight: 600; }
.summary { background: #f0f4f8; padding: 16px; border-radius: 8px;
           display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; }
.summary-item .label { font-size: 12px; color: #7f8c8d; text-transform: uppercase; }
.summary-item .value { font-size: 24px; font-weight: 700; color: #2c3e50; margin-top: 4px; }
footer { text-align: center; padding: 20px; color: #7f8c8d; font-size: 12px; }
.empty { color: #95a5a6; font-style: italic; padding: 12px; }
@media print {
  body { background: white; padding: 0; }
  header { background: #667eea !important; -webkit-print-color-adjust: exact; }
  .actions { display: none; }
  section { box-shadow: none; page-break-inside: avoid; border: 1px solid #ddd; }
  .badge, .pct-fill { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
}
</style>
</head>
<body>
<div class="container">
HTMLHEAD

    local q_label
    if [[ "$CLUSTER_QUORATE" == "1" ]]; then
        q_label='<span class="badge badge-running">✓ Quorate</span>'
    else
        q_label='<span class="badge badge-offline">✗ NOT Quorate</span>'
    fi

cat << HTMLHEADER
<header>
  <div>
    <h1>🖥️ ${CLUSTER_NAME} – Status Report</h1>
    <div class="meta">Wygenerowano: ${TIMESTAMP}</div>
  </div>
  <div class="actions">
    <button onclick="window.print()">📄 PDF</button>
    <button onclick="exportExcel()">📊 Excel</button>
    <button onclick="exportCSV()">📋 CSV</button>
    <button onclick="copyJSON()">📦 JSON</button>
    <button onclick="location.reload()">🔄 Reload</button>
  </div>
</header>

<section>
  <h2>📡 Klaster</h2>
  <div class="info-grid">
    <div class="info-item"><div class="label">Nazwa</div><div class="value">${CLUSTER_NAME}</div></div>
    <div class="info-item"><div class="label">Wersja config</div><div class="value">${CLUSTER_VERSION}</div></div>
    <div class="info-item"><div class="label">Liczba node-ów</div><div class="value">${CLUSTER_NODES}</div></div>
    <div class="info-item"><div class="label">Quorum</div><div class="value">${q_label}</div></div>
  </div>

  <h3>Node-y</h3>
  <table>
    <thead><tr><th>Node</th><th>IP</th><th>Node ID</th><th>Status</th></tr></thead>
    <tbody>
HTMLHEADER

    echo "$NODES_JSON" | jq -r '.[] | "\(.name)|\(.ip)|\(.nodeid)|\(.online)|\(.local)"' \
    | while IFS='|' read -r name ip nodeid online local; do
        local sb lm=""
        [[ "$online" == "1" ]] && sb='<span class="badge badge-online">✓ online</span>' || sb='<span class="badge badge-offline">✗ offline</span>'
        [[ "$local" == "1" ]] && lm=' <small style="color:#7f8c8d">(local)</small>'
        echo "      <tr><td>$(html_escape "$name")${lm}</td><td>$(html_escape "$ip")</td><td>${nodeid}</td><td>${sb}</td></tr>"
    done

cat << 'HTMLENDC'
    </tbody>
  </table>
</section>
HTMLENDC

    for node in $NODE_NAMES; do
        echo "<section class=\"node-section\">"
        echo "  <h2>🖥️ Node: $(html_escape "$node")</h2>"
        html_disks "$node"
        html_storage "$node"
        html_vms "$node"
        html_lxc "$node"
        echo "</section>"
    done

    # Summary
    local tv rv sv tc rc sc tpl tmb tmh
    tv=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "qemu" and (.template // 0) == 0)] | length')
    rv=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "qemu" and (.template // 0) == 0 and .status == "running")] | length')
    sv=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "qemu" and (.template // 0) == 0 and .status == "stopped")] | length')
    tc=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "lxc" and (.template // 0) == 0)] | length')
    rc=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "lxc" and (.template // 0) == 0 and .status == "running")] | length')
    sc=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "lxc" and (.template // 0) == 0 and .status == "stopped")] | length')
    tpl=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.type == "lxc" and .template == 1)] | length')
    tmb=$(echo "$RESOURCES_JSON" | jq '[.[] | select(.status == "running") | .maxmem // 0] | add')
    tmh=$(human_bytes "$tmb")

cat << HTMLSUM
<section>
  <h2>📊 Podsumowanie</h2>
  <div class="summary">
    <div class="summary-item"><div class="label">VM-ki total</div><div class="value">${tv}</div></div>
    <div class="summary-item"><div class="label">VM running</div><div class="value" style="color:#28a745">${rv}</div></div>
    <div class="summary-item"><div class="label">VM stopped</div><div class="value" style="color:#6c757d">${sv}</div></div>
    <div class="summary-item"><div class="label">LXC total</div><div class="value">${tc}</div></div>
    <div class="summary-item"><div class="label">LXC running</div><div class="value" style="color:#28a745">${rc}</div></div>
    <div class="summary-item"><div class="label">LXC templates</div><div class="value" style="color:#856404">${tpl}</div></div>
    <div class="summary-item"><div class="label">RAM (running)</div><div class="value">${tmh}</div></div>
  </div>
</section>

<footer>
  Generated by cluster-status.sh v2 · ${TIMESTAMP}<br>
  Repo: <a href="http://gitea.lan:3000/tomasz/proxmox-tools" style="color:#3498db">tomasz/proxmox-tools</a>
</footer>
</div>

<script src="https://cdn.sheetjs.com/xlsx-0.20.1/package/dist/xlsx.full.min.js"></script>
<script>
document.querySelectorAll('table').forEach(table => {
  table.querySelectorAll('th').forEach((th, i) => {
    th.addEventListener('click', () => {
      const tbody = table.querySelector('tbody');
      const rows = Array.from(tbody.querySelectorAll('tr'));
      const asc = !th.classList.contains('sorted-asc');
      table.querySelectorAll('th').forEach(t => t.classList.remove('sorted-asc', 'sorted-desc'));
      th.classList.add(asc ? 'sorted-asc' : 'sorted-desc');
      rows.sort((a, b) => {
        const aV = a.cells[i].innerText.trim();
        const bV = b.cells[i].innerText.trim();
        const aN = parseFloat(aV), bN = parseFloat(bV);
        if (!isNaN(aN) && !isNaN(bN)) return asc ? aN - bN : bN - aN;
        return asc ? aV.localeCompare(bV) : bV.localeCompare(aV);
      });
      rows.forEach(r => tbody.appendChild(r));
    });
  });
});

function exportExcel() {
  const wb = XLSX.utils.book_new();
  let sheetNum = 1;
  document.querySelectorAll('section').forEach(section => {
    const h2 = section.querySelector('h2');
    section.querySelectorAll('table').forEach(table => {
      const h3 = table.previousElementSibling;
      const name = (h2 ? h2.innerText : 'Sheet') + (h3 && h3.tagName === 'H3' ? ' - ' + h3.innerText : '');
      const cleanName = name.replace(/[^a-zA-Z0-9 _-]/g, '').substring(0, 28).trim() || 'Sheet' + sheetNum;
      try {
        const ws = XLSX.utils.table_to_sheet(table);
        XLSX.utils.book_append_sheet(wb, ws, cleanName);
      } catch(e) {
        XLSX.utils.book_append_sheet(wb, XLSX.utils.table_to_sheet(table), 'Sheet' + sheetNum);
      }
      sheetNum++;
    });
  });
  const fname = 'cluster-status-' + new Date().toISOString().slice(0,16).replace(/[:T]/g, '-') + '.xlsx';
  XLSX.writeFile(wb, fname);
}

function exportCSV() {
  let csv = '\ufeff';
  document.querySelectorAll('section').forEach(section => {
    const h2 = section.querySelector('h2');
    if (h2) csv += '# ' + h2.innerText + '\n';
    section.querySelectorAll('table').forEach(table => {
      const h3 = table.previousElementSibling;
      if (h3 && h3.tagName === 'H3') csv += '## ' + h3.innerText + '\n';
      table.querySelectorAll('tr').forEach(tr => {
        const cells = Array.from(tr.querySelectorAll('th, td')).map(c => {
          let v = c.innerText.trim().replace(/"/g, '""');
          if (v.includes(',') || v.includes('"') || v.includes('\n')) v = '"' + v + '"';
          return v;
        });
        csv += cells.join(',') + '\n';
      });
      csv += '\n';
    });
  });
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'cluster-status-' + new Date().toISOString().slice(0,16).replace(/[:T]/g, '-') + '.csv';
  a.click();
}

function copyJSON() {
  const data = { generated: new Date().toISOString(), sections: {} };
  document.querySelectorAll('section').forEach(section => {
    const h2 = section.querySelector('h2');
    if (!h2) return;
    const sectionData = {};
    section.querySelectorAll('table').forEach(table => {
      const h3 = table.previousElementSibling;
      const tableName = (h3 && h3.tagName === 'H3') ? h3.innerText : 'data';
      const headers = Array.from(table.querySelectorAll('thead th')).map(th => th.innerText.replace(/ [⇅↑↓]/g, '').trim());
      const rows = Array.from(table.querySelectorAll('tbody tr')).map(tr => {
        const obj = {};
        Array.from(tr.cells).forEach((td, i) => { obj[headers[i]] = td.innerText.trim(); });
        return obj;
      });
      sectionData[tableName] = rows;
    });
    data.sections[h2.innerText] = sectionData;
  });
  navigator.clipboard.writeText(JSON.stringify(data, null, 2)).then(() => {
    alert('JSON skopiowany do schowka!');
  });
}
</script>
</body>
</html>
HTMLSUM
}

html_disks() {
    local node=$1
    echo "  <h3>💽 Fizyczne dyski</h3>"
    local d
    d=$(pvesh get "/nodes/${node}/disks/list" --output-format json 2>/dev/null)
    if [[ -z "$d" || "$d" == "null" || "$d" == "[]" ]]; then
        echo "  <p class=\"empty\">(brak danych)</p>"
        return
    fi
    echo "  <table>"
    echo "    <thead><tr><th>Device</th><th>Model</th><th>Typ</th><th>Size</th><th>FS</th><th>Health</th><th>Serial</th></tr></thead>"
    echo "    <tbody>"
    echo "$d" | jq -r '.[] | "\(.devpath)|\(.model // "?")|\(.size // 0)|\(.used // "?")|\(.health // "?")|\(.vendor // "")|\(.serial // "")"' \
    | while IFS='|' read -r dp m sz u h v sr; do
        local dn sh dt tb hc fs
        dn=$(basename "$dp")
        sh=$(human_bytes "$sz")
        dt=$(detect_disk_type "$dp" "$m" "$v")
        case "$dt" in
            NVMe)    tb='<span class="badge badge-nvme">NVMe</span>' ;;
            SSD)     tb='<span class="badge badge-ssd">SSD</span>' ;;
            HDD)     tb='<span class="badge badge-hdd">HDD</span>' ;;
            USB-HDD) tb='<span class="badge badge-usb">USB-HDD</span>' ;;
        esac
        case "$h" in
            PASSED) hc='<span class="health-passed">PASSED</span>' ;;
            FAILED) hc='<span class="health-failed">FAILED</span>' ;;
            *)      hc='<span class="health-unknown">?</span>' ;;
        esac
        fs="$u"
        [[ -z "$fs" || "$fs" == "?" ]] && fs="-"
        echo "      <tr><td>$(html_escape "$dn")</td><td>$(html_escape "$m")</td><td>${tb}</td><td>${sh}</td><td>$(html_escape "$fs")</td><td>${hc}</td><td><small>$(html_escape "$sr")</small></td></tr>"
    done
    echo "    </tbody></table>"
}

html_storage() {
    local node=$1
    echo "  <h3>📦 Storage Proxmox</h3>"
    local sj
    sj=$(pvesh get "/nodes/${node}/storage" --output-format json 2>/dev/null)
    echo "  <table>"
    echo "    <thead><tr><th>Name</th><th>Type</th><th>Total</th><th>Used</th><th>Avail</th><th>%</th><th>Status</th></tr></thead>"
    echo "    <tbody>"
    echo "$sj" | jq -r '.[] | "\(.storage)|\(.type)|\(.total // 0)|\(.used // 0)|\(.avail // 0)|\(.used_fraction // 0)|\(.active // 0)|\(.enabled // 0)"' \
    | sort \
    | while IFS='|' read -r name tp t u a f ac en; do
        local th uh ah ps sb
        if [[ "$ac" == "1" ]]; then
            sb='<span class="badge badge-active">● active</span>'
            th=$(human_bytes "$t"); uh=$(human_bytes "$u"); ah=$(human_bytes "$a")
            local p pc
            p=$(format_percent_raw "$f")
            pc="pct-low"
            [[ $p -ge 75 ]] && pc="pct-med"
            [[ $p -ge 90 ]] && pc="pct-high"
            ps="<div class=\"pct-bar\"><div class=\"pct-fill ${pc}\" style=\"width:${p}%\"></div></div><span class=\"pct-text\">${p}%</span>"
        else
            sb='<span class="badge badge-disabled">○ disabled</span>'
            th="-"; uh="-"; ah="-"; ps="-"
        fi
        echo "      <tr><td><strong>$(html_escape "$name")</strong></td><td>${tp}</td><td>${th}</td><td>${uh}</td><td>${ah}</td><td>${ps}</td><td>${sb}</td></tr>"
    done
    echo "    </tbody></table>"
}

html_vms() {
    local node=$1
    echo "  <h3>🖥️ VM-ki KVM</h3>"
    local vms
    vms=$(echo "$RESOURCES_JSON" | jq -r --arg n "$node" \
        '.[] | select(.type == "qemu" and .node == $n and (.template // 0) == 0) | "\(.vmid)|\(.name)|\(.status)|\(.maxcpu)|\(.maxmem)|\(.maxdisk)"' | sort -n)
    if [[ -z "$vms" ]]; then
        echo "  <p class=\"empty\">(brak VM-ek)</p>"
        return
    fi
    echo "  <table>"
    echo "    <thead><tr><th>VMID</th><th>Nazwa</th><th>Status</th><th>CPU</th><th>RAM</th><th>Disk (max)</th></tr></thead>"
    echo "    <tbody>"
    echo "$vms" | while IFS='|' read -r vmid name status cpu mem disk; do
        local mh dh sb
        mh=$(human_bytes "$mem"); dh=$(human_bytes "$disk")
        case "$status" in
            running) sb='<span class="badge badge-running">● running</span>' ;;
            stopped) sb='<span class="badge badge-stopped">○ stopped</span>' ;;
            *)       sb="<span class=\"badge\">${status}</span>" ;;
        esac
        echo "      <tr><td>${vmid}</td><td>$(html_escape "$name")</td><td>${sb}</td><td>${cpu}</td><td>${mh}</td><td>${dh}</td></tr>"
    done
    echo "    </tbody></table>"
}

html_lxc() {
    local node=$1
    echo "  <h3>📦 Kontenery LXC</h3>"
    local cts
    cts=$(echo "$RESOURCES_JSON" | jq -r --arg n "$node" \
        '.[] | select(.type == "lxc" and .node == $n) | "\(.vmid)|\(.name)|\(.status)|\(.maxcpu)|\(.maxmem)|\(.maxdisk)|\(.template // 0)"' | sort -n)
    if [[ -z "$cts" ]]; then
        echo "  <p class=\"empty\">(brak LXC)</p>"
        return
    fi
    echo "  <table>"
    echo "    <thead><tr><th>CTID</th><th>Nazwa</th><th>Status</th><th>CPU</th><th>RAM</th><th>Disk (max)</th></tr></thead>"
    echo "    <tbody>"
    echo "$cts" | while IFS='|' read -r ctid name status cpu mem disk tmpl; do
        local mh dh sb nl
        mh=$(human_bytes "$mem"); dh=$(human_bytes "$disk")
        case "$status" in
            running) sb='<span class="badge badge-running">● running</span>' ;;
            stopped) sb='<span class="badge badge-stopped">○ stopped</span>' ;;
            *)       sb="<span class=\"badge\">${status}</span>" ;;
        esac
        nl=$(html_escape "$name")
        [[ "$tmpl" == "1" ]] && nl+=' <span class="badge badge-template">template</span>'
        echo "      <tr><td>${ctid}</td><td>${nl}</td><td>${sb}</td><td>${cpu}</td><td>${mh}</td><td>${dh}</td></tr>"
    done
    echo "    </tbody></table>"
}

# ============================================================
# MAIN
# ============================================================
main() {
    check_prereqs
    collect_data

    if [[ -n "$OUTPUT_FILE" ]]; then
        case "$FORMAT" in
            pretty) output_pretty > "$OUTPUT_FILE" ;;
            html)   output_html > "$OUTPUT_FILE" ;;
            json)   output_json > "$OUTPUT_FILE" ;;
            csv)    output_csv > "$OUTPUT_FILE" ;;
        esac
        echo "Zapisano: $OUTPUT_FILE" >&2
    else
        case "$FORMAT" in
            pretty) output_pretty ;;
            html)   output_html ;;
            json)   output_json ;;
            csv)    output_csv ;;
        esac
    fi
}

main "$@"
