#!/bin/bash
# ============================================================
# cluster-status.sh - Status klastra Proxmox CLUSTER01
# ============================================================
# Pokazuje pełen obraz: klaster, dyski fizyczne, storage Proxmox,
# VM-ki KVM, kontenery LXC - per każdy node.
#
# Wymagania:
#   - pvesh (Proxmox VE - builtin)
#   - jq (auto-install jeśli brak)
#
# Użycie:
#   ./cluster-status.sh              # pretty, color
#   ./cluster-status.sh --no-color   # ASCII, bez kolorów (do logów)
#   ./cluster-status.sh -v           # verbose (więcej szczegółów)
#   ./cluster-status.sh -h           # pomoc
#
# Autor: Tomasz Werwinski (tomasz@ssh22.pl)
# Repo:  gitea.lan:3000/tomasz/proxmox-tools
# ============================================================

set -u  # nie używaj NIE zdefiniowanych zmiennych

# ============================================================
# ARGUMENTY
# ============================================================
VERBOSE=0
USE_COLOR=1

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --no-color)
            USE_COLOR=0
            shift
            ;;
        -h|--help)
            grep -E "^# " "$0" | head -30 | sed 's/^# //'
            exit 0
            ;;
        *)
            echo "Nieznany argument: $1" >&2
            echo "Użyj -h dla pomocy" >&2
            exit 1
            ;;
    esac
done

# ============================================================
# KOLORY ANSI
# ============================================================
if [[ $USE_COLOR -eq 1 ]] && [[ -t 1 ]]; then
    BOLD="\033[1m"
    DIM="\033[2m"
    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    BLUE="\033[34m"
    MAGENTA="\033[35m"
    CYAN="\033[36m"
    WHITE="\033[37m"
    RESET="\033[0m"
else
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    MAGENTA=""
    CYAN=""
    WHITE=""
    RESET=""
fi

# ============================================================
# PREREQ CHECK
# ============================================================
check_prereqs() {
    if ! command -v pvesh &>/dev/null; then
        echo -e "${RED}BŁĄD:${RESET} pvesh nie znaleziono. Skrypt musi być uruchomiony na node Proxmox." >&2
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}UWAGA:${RESET} jq nie zainstalowane. Instaluję..."
        apt update -qq >/dev/null 2>&1
        apt install -y -qq jq >/dev/null 2>&1
        if ! command -v jq &>/dev/null; then
            echo -e "${RED}BŁĄD:${RESET} Nie udało się zainstalować jq" >&2
            exit 1
        fi
        echo -e "${GREEN}OK:${RESET} jq zainstalowane"
    fi
}

# ============================================================
# FORMAT HELPERS
# ============================================================

# Bajty -> czytelny format (GB/MB)
human_bytes() {
    local bytes=$1
    if [[ -z "$bytes" ]] || [[ "$bytes" == "null" ]] || [[ "$bytes" -eq 0 ]]; then
        echo "0"
        return
    fi
    awk -v b="$bytes" '
    BEGIN {
        if (b >= 1099511627776) printf "%.1fT", b/1099511627776
        else if (b >= 1073741824) printf "%.1fG", b/1073741824
        else if (b >= 1048576) printf "%.1fM", b/1048576
        else if (b >= 1024) printf "%.1fK", b/1024
        else printf "%dB", b
    }'
}

# Procent (0-1) -> czytelny format z kolorami
format_percent() {
    local frac=$1
    local pct
    pct=$(awk -v f="$frac" 'BEGIN { printf "%.0f", f*100 }')
    if [[ $pct -ge 90 ]]; then
        echo -e "${RED}${pct}%${RESET}"
    elif [[ $pct -ge 75 ]]; then
        echo -e "${YELLOW}${pct}%${RESET}"
    else
        echo -e "${GREEN}${pct}%${RESET}"
    fi
}

# Status running/stopped z kolorem
format_status() {
    local status=$1
    case "$status" in
        running)
            echo -e "${GREEN}● running${RESET}"
            ;;
        stopped)
            echo -e "${DIM}○ stopped${RESET}"
            ;;
        *)
            echo -e "${YELLOW}? $status${RESET}"
            ;;
    esac
}

# Wykryj typ dysku (SSD/HDD/USB) na podstawie /sys/block
detect_disk_type() {
    local node=$1
    local devpath=$2
    local devname
    devname=$(basename "$devpath")

    # Uruchom na docelowym node przez pvesh
    local rotational removable
    rotational=$(pvesh get "/nodes/${node}/disks/list" --output-format json 2>/dev/null \
        | jq -r ".[] | select(.devpath == \"${devpath}\") | .rpm // 0")
    removable=0  # pvesh nie daje removable, użyjemy modelu

    # Wykrywanie po modelu (heuristic)
    local model
    model=$(pvesh get "/nodes/${node}/disks/list" --output-format json 2>/dev/null \
        | jq -r ".[] | select(.devpath == \"${devpath}\") | .model // \"\"")

    if [[ "$model" == *"SSD"* ]] || [[ "$model" == *"NVMe"* ]] || [[ "$rotational" == "0" ]]; then
        echo "SSD"
    elif [[ "$model" == *"Expansion"* ]] || [[ "$model" == *"USB"* ]]; then
        echo "USB-HDD"
    else
        echo "HDD"
    fi
}

# ============================================================
# SEKCJA: KLASTER
# ============================================================
show_cluster_info() {
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║         CLUSTER STATUS REPORT                                    ║${RESET}"
    echo -e "${BOLD}${CYAN}║         $(date '+%Y-%m-%d %H:%M:%S')                                      ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    local status_json
    status_json=$(pvesh get /cluster/status --output-format json 2>/dev/null)

    local cluster_info
    cluster_info=$(echo "$status_json" | jq -r '.[] | select(.type == "cluster")')

    local cluster_name nodes_count quorate version
    cluster_name=$(echo "$cluster_info" | jq -r '.name')
    nodes_count=$(echo "$cluster_info" | jq -r '.nodes')
    quorate=$(echo "$cluster_info" | jq -r '.quorate')
    version=$(echo "$cluster_info" | jq -r '.version')

    echo -e "${BOLD}▸ KLASTER${RESET}"
    echo -e "  Nazwa:        ${BOLD}${cluster_name}${RESET}"
    echo -e "  Wersja conf:  ${version}"
    echo -e "  Node-y:       ${nodes_count}"
    if [[ "$quorate" == "1" ]]; then
        echo -e "  Quorum:       ${GREEN}✓ Quorate${RESET}"
    else
        echo -e "  Quorum:       ${RED}✗ NOT QUORATE${RESET}"
    fi
    echo ""

    echo -e "  ${BOLD}Node${RESET}      ${BOLD}IP${RESET}                ${BOLD}Status${RESET}"
    echo -e "  ─────────────────────────────────────────────"
    echo "$status_json" | jq -r '.[] | select(.type == "node") | "\(.name)|\(.ip)|\(.online)|\(.local)"' \
    | while IFS='|' read -r name ip online local; do
        local status_label="" local_label=""
        if [[ "$online" == "1" ]]; then
            status_label="${GREEN}✓ online${RESET}"
        else
            status_label="${RED}✗ offline${RESET}"
        fi
        if [[ "$local" == "1" ]]; then
            local_label=" ${DIM}(local)${RESET}"
        fi
        printf "  %-10s%-18s" "$name" "$ip"
        echo -e "${status_label}${local_label}"
    done
    echo ""
}

# ============================================================
# SEKCJA: per NODE - DYSKI FIZYCZNE
# ============================================================
show_node_disks() {
    local node=$1

    echo -e "${BOLD}${BLUE}▸ ${node} — Fizyczne dyski${RESET}"
    echo -e "  ${BOLD}Device${RESET}    ${BOLD}Model${RESET}                          ${BOLD}Typ${RESET}      ${BOLD}Size${RESET}     ${BOLD}FS${RESET}        ${BOLD}Health${RESET}"
    echo -e "  ───────────────────────────────────────────────────────────────────────────"

    local disks_json
    disks_json=$(pvesh get "/nodes/${node}/disks/list" --output-format json 2>/dev/null)

    if [[ -z "$disks_json" ]] || [[ "$disks_json" == "null" ]]; then
        echo -e "  ${DIM}(brak danych)${RESET}"
        echo ""
        return
    fi

    echo "$disks_json" | jq -r '.[] | "\(.devpath)|\(.model // "?")|\(.size // 0)|\(.used // "?")|\(.health // "?")|\(.vendor // "")"' \
    | while IFS='|' read -r devpath model size used health vendor; do
        local devname size_h health_color disk_type model_short
        devname=$(basename "$devpath")
        size_h=$(human_bytes "$size")

        # Skróć model jeśli za długi
        if [[ ${#model} -gt 28 ]]; then
            model_short="${model:0:25}..."
        else
            model_short="$model"
        fi

        # Wykryj typ (uproszczony - po modelu/vendor)
        if [[ "$model" == *"SSD"* ]] || [[ "$model" == *"NVMe"* ]] || [[ "$model" == *"EVO"* ]]; then
            disk_type="${GREEN}SSD${RESET}    "
        elif [[ "$model" == *"Expansion"* ]] || [[ "$vendor" == *"Seagate"* && "$model" == *"Expansion"* ]]; then
            disk_type="${YELLOW}USB-HDD${RESET}"
        else
            disk_type="${BLUE}HDD${RESET}    "
        fi

        # Health color
        case "$health" in
            PASSED)
                health_color="${GREEN}PASSED${RESET}"
                ;;
            UNKNOWN|"")
                health_color="${DIM}?${RESET}     "
                ;;
            FAILED)
                health_color="${RED}FAILED${RESET}"
                ;;
            *)
                health_color="${YELLOW}${health}${RESET}"
                ;;
        esac

        # FS może być "ext4", "BIOS boot", "LVM2_member", "" - pokaż tylko user-friendly
        local fs_label="$used"
        if [[ -z "$fs_label" ]] || [[ "$fs_label" == "?" ]]; then
            fs_label="-"
        fi

        printf "  %-10s%-32s" "$devname" "$model_short"
        echo -ne "$disk_type"
        printf "  %-9s%-10s" "$size_h" "$fs_label"
        echo -e "$health_color"
    done
    echo ""
}

# ============================================================
# SEKCJA: per NODE - STORAGE PROXMOX
# ============================================================
show_node_storage() {
    local node=$1

    echo -e "${BOLD}${MAGENTA}▸ ${node} — Storage Proxmox${RESET}"
    echo -e "  ${BOLD}Name${RESET}                  ${BOLD}Type${RESET}     ${BOLD}Total${RESET}    ${BOLD}Used${RESET}     ${BOLD}Avail${RESET}    ${BOLD}%${RESET}      ${BOLD}Status${RESET}"
    echo -e "  ─────────────────────────────────────────────────────────────────────────────"

    local storage_json
    storage_json=$(pvesh get "/nodes/${node}/storage" --output-format json 2>/dev/null)

    echo "$storage_json" | jq -r '.[] | "\(.storage)|\(.type)|\(.total // 0)|\(.used // 0)|\(.avail // 0)|\(.used_fraction // 0)|\(.active // 0)|\(.enabled // 0)"' \
    | sort \
    | while IFS='|' read -r name type total used avail frac active enabled; do
        local total_h used_h avail_h pct_str status_label

        if [[ "$active" == "1" ]]; then
            status_label="${GREEN}● active${RESET}"
            total_h=$(human_bytes "$total")
            used_h=$(human_bytes "$used")
            avail_h=$(human_bytes "$avail")
            pct_str=$(format_percent "$frac")
        elif [[ "$enabled" == "0" ]]; then
            status_label="${DIM}○ disabled${RESET}"
            total_h="-"
            used_h="-"
            avail_h="-"
            pct_str="-"
        else
            status_label="${YELLOW}? inactive${RESET}"
            total_h="-"
            used_h="-"
            avail_h="-"
            pct_str="-"
        fi

        printf "  %-22s%-9s%-9s%-9s%-9s" "$name" "$type" "$total_h" "$used_h" "$avail_h"
        echo -ne "$(printf "%-15s" "$pct_str")"
        echo -e "$status_label"
    done
    echo ""
}

# ============================================================
# SEKCJA: VM-ki KVM per NODE
# ============================================================
show_node_vms() {
    local node=$1
    local resources_json=$2

    echo -e "${BOLD}${GREEN}▸ ${node} — VM-ki KVM${RESET}"
    echo -e "  ${BOLD}VMID${RESET}  ${BOLD}Nazwa${RESET}                    ${BOLD}Status${RESET}        ${BOLD}CPU${RESET}    ${BOLD}RAM${RESET}      ${BOLD}Disk(max)${RESET}"
    echo -e "  ─────────────────────────────────────────────────────────────────────"

    local vms
    vms=$(echo "$resources_json" | jq -r --arg n "$node" \
        '.[] | select(.type == "qemu" and .node == $n and (.template // 0) == 0) | "\(.vmid)|\(.name)|\(.status)|\(.maxcpu)|\(.maxmem)|\(.maxdisk)"' \
        | sort -n)

    if [[ -z "$vms" ]]; then
        echo -e "  ${DIM}(brak VM-ek na tym node)${RESET}"
        echo ""
        return
    fi

    echo "$vms" | while IFS='|' read -r vmid name status cpu mem disk; do
        local mem_h disk_h status_str
        mem_h=$(human_bytes "$mem")
        disk_h=$(human_bytes "$disk")
        status_str=$(format_status "$status")

        # Truncate name if too long
        if [[ ${#name} -gt 22 ]]; then
            name="${name:0:19}..."
        fi

        printf "  %-6s%-25s" "$vmid" "$name"
        echo -ne "$(printf "%-20s" "$status_str")"
        printf "%-7s%-9s%s\n" "${cpu}c" "$mem_h" "$disk_h"

        # Verbose - pokaż dyski z configu
        if [[ $VERBOSE -eq 1 ]] && [[ "$status" == "running" || "$status" == "stopped" ]]; then
            local config_json
            config_json=$(pvesh get "/nodes/${node}/qemu/${vmid}/config" --output-format json 2>/dev/null)
            if [[ -n "$config_json" ]]; then
                local sockets cores
                sockets=$(echo "$config_json" | jq -r '.sockets // 1')
                cores=$(echo "$config_json" | jq -r '.cores // 1')
                echo -e "        ${DIM}└─ CPU: ${sockets}×${cores} = $((sockets*cores)) vCPU${RESET}"

                # Dyski (scsiN, virtioN, sataN, ideN)
                echo "$config_json" | jq -r 'to_entries[] | select(.key | test("^(scsi|virtio|sata|ide)[0-9]+$")) | "\(.key)=\(.value)"' \
                | while read -r line; do
                    echo -e "        ${DIM}└─ disk ${line}${RESET}"
                done
            fi
        fi
    done
    echo ""
}

# ============================================================
# SEKCJA: LXC per NODE
# ============================================================
show_node_lxc() {
    local node=$1
    local resources_json=$2

    echo -e "${BOLD}${YELLOW}▸ ${node} — Kontenery LXC${RESET}"
    echo -e "  ${BOLD}CTID${RESET}  ${BOLD}Nazwa${RESET}                    ${BOLD}Status${RESET}        ${BOLD}CPU${RESET}    ${BOLD}RAM${RESET}      ${BOLD}Disk(max)${RESET}"
    echo -e "  ─────────────────────────────────────────────────────────────────────"

    local cts
    cts=$(echo "$resources_json" | jq -r --arg n "$node" \
        '.[] | select(.type == "lxc" and .node == $n) | "\(.vmid)|\(.name)|\(.status)|\(.maxcpu)|\(.maxmem)|\(.maxdisk)|\(.template // 0)"' \
        | sort -n)

    if [[ -z "$cts" ]]; then
        echo -e "  ${DIM}(brak LXC na tym node)${RESET}"
        echo ""
        return
    fi

    echo "$cts" | while IFS='|' read -r ctid name status cpu mem disk template; do
        local mem_h disk_h status_str name_label
        mem_h=$(human_bytes "$mem")
        disk_h=$(human_bytes "$disk")
        status_str=$(format_status "$status")

        if [[ ${#name} -gt 22 ]]; then
            name="${name:0:19}..."
        fi

        # Template marker
        name_label="$name"
        if [[ "$template" == "1" ]]; then
            name_label="${name} ${DIM}[template]${RESET}"
        fi

        printf "  %-6s" "$ctid"
        echo -ne "$(printf "%-25s" "$name_label")"
        echo -ne "$(printf "%-20s" "$status_str")"
        printf "%-7s%-9s%s\n" "${cpu}c" "$mem_h" "$disk_h"

        # Verbose
        if [[ $VERBOSE -eq 1 ]]; then
            local config_json
            config_json=$(pvesh get "/nodes/${node}/lxc/${ctid}/config" --output-format json 2>/dev/null)
            if [[ -n "$config_json" ]]; then
                local rootfs
                rootfs=$(echo "$config_json" | jq -r '.rootfs // "?"')
                echo -e "        ${DIM}└─ rootfs: ${rootfs}${RESET}"
            fi
        fi
    done
    echo ""
}

# ============================================================
# PODSUMOWANIE
# ============================================================
show_summary() {
    local resources_json=$1

    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}▸ PODSUMOWANIE${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════${RESET}"

    local total_vms running_vms stopped_vms
    total_vms=$(echo "$resources_json" | jq '[.[] | select(.type == "qemu" and (.template // 0) == 0)] | length')
    running_vms=$(echo "$resources_json" | jq '[.[] | select(.type == "qemu" and (.template // 0) == 0 and .status == "running")] | length')
    stopped_vms=$(echo "$resources_json" | jq '[.[] | select(.type == "qemu" and (.template // 0) == 0 and .status == "stopped")] | length')

    local total_cts running_cts stopped_cts template_cts
    total_cts=$(echo "$resources_json" | jq '[.[] | select(.type == "lxc" and (.template // 0) == 0)] | length')
    running_cts=$(echo "$resources_json" | jq '[.[] | select(.type == "lxc" and (.template // 0) == 0 and .status == "running")] | length')
    stopped_cts=$(echo "$resources_json" | jq '[.[] | select(.type == "lxc" and (.template // 0) == 0 and .status == "stopped")] | length')
    template_cts=$(echo "$resources_json" | jq '[.[] | select(.type == "lxc" and .template == 1)] | length')

    # Sumaryczna RAM (running tylko)
    local total_mem_bytes
    total_mem_bytes=$(echo "$resources_json" | jq '[.[] | select(.status == "running") | .maxmem // 0] | add')
    local total_mem_h
    total_mem_h=$(human_bytes "$total_mem_bytes")

    echo -e "  VM-ki KVM:    ${total_vms} (${GREEN}${running_vms} running${RESET}, ${DIM}${stopped_vms} stopped${RESET})"
    echo -e "  LXC:          ${total_cts} (${GREEN}${running_cts} running${RESET}, ${DIM}${stopped_cts} stopped${RESET})${DIM}, ${template_cts} template${RESET}"
    echo -e "  RAM (running): ${total_mem_h}"
    echo ""
}

# ============================================================
# MAIN
# ============================================================
main() {
    check_prereqs

    # Klaster
    show_cluster_info

    # Pobierz raz - resources i node listę
    local resources_json
    resources_json=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)

    local nodes
    nodes=$(pvesh get /cluster/status --output-format json 2>/dev/null \
        | jq -r '.[] | select(.type == "node" and .online == 1) | .name' | sort)

    # Per node
    for node in $nodes; do
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════${RESET}"
        echo -e "${BOLD}${CYAN} NODE: ${node}${RESET}"
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════${RESET}"
        echo ""

        show_node_disks "$node"
        show_node_storage "$node"
        show_node_vms "$node" "$resources_json"
        show_node_lxc "$node" "$resources_json"
    done

    # Podsumowanie
    show_summary "$resources_json"
}

main "$@"
