#!/usr/bin/env bash
# Day-2: adds worker node(s) described in config/new-nodes.csv to an
# already-installed cluster. Creates the VMs, builds a day-2 discovery ISO
# with `oc adm node-image create` against the running cluster, boots the
# new VMs from it, and approves the resulting node CSRs.
#
# Usage:
#   scripts/add-nodes.sh                         # auto-generate nodes-config.yaml
#   scripts/add-nodes.sh --manual-nodes-config   # use your own config/nodes-config.yaml
#
# The cluster it adds nodes to is the one under clusters/<cluster>/ (same
# layout install.sh creates); override with KUBECONFIG to target another.


# ======================
#  PRE-RUN set defaults
# ======================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Colour/log helpers and require_tools() are shared with install.sh.
source scripts/check-prereqs.sh

# --manual-nodes-config skips generating nodes-config.yaml from the CSV and
# uses the file you wrote instead. VM creation still happens from the CSV
# either way (that's what actually provisions the hardware).
MODE="auto"
if [[ "${1:-}" == "--manual-nodes-config" ]]; then
  MODE="manual"
elif [[ -n "${1:-}" ]]; then
  die "unknown option '$1' (only --manual-nodes-config is supported)"
fi

say_banner "Add worker node(s) to an existing cluster"


# ======================
#  PRE-RUN validation
# ======================

require_tools govc oc

[[ -f config/vcenter-vars.env ]] || die "missing config/vcenter-vars.env"
[[ -f config/cluster-vars.env ]] || die "missing config/cluster-vars.env"
[[ -f config/new-nodes.csv ]]    || die "missing config/new-nodes.csv (cp config/examples/new-nodes.csv config/new-nodes.csv)"

set -a
source config/vcenter-vars.env
source config/cluster-vars.env
set +a
mkdir -p "$GOVC_HOME"

# Day-2 control-plane changes aren't handled by this flow, so refuse early
# rather than let oc adm node-image create fail confusingly later.
if grep -vE '^[[:space:]]*(#|$)' config/new-nodes.csv | tail -n +2 | awk -F',' '$2!="worker"' | grep -q .; then
  die "config/new-nodes.csv: only role=worker is supported for day-2 node addition"
fi

# Same clusters/<cluster>/ layout install.sh writes, so the kubeconfig is
# found without any extra configuration.
CLUSTERS_ROOT="clusters"
INSTALL_DIR="$CLUSTERS_ROOT/${INSTALL_DIR:-$CLUSTER_NAME}"

# oc adm node-image create needs the kubeconfig to know which running cluster
# to embed a pull secret/API address for in the day-2 ISO.
KUBECONFIG="${KUBECONFIG:-$(pwd)/$INSTALL_DIR/auth/kubeconfig}"
[[ -f "$KUBECONFIG" ]] || die "kubeconfig not found at $KUBECONFIG (set KUBECONFIG to point at your cluster)"
export KUBECONFIG

RESOLVED_CSV="config/new-nodes.resolved.csv"
DAY2_DIR="$INSTALL_DIR/day2-nodes"

say_info "Cluster        : ${C_BOLD}${CLUSTER_NAME}.${BASE_DOMAIN}${C_RESET}"
say_info "kubeconfig     : $KUBECONFIG"
say_info "nodes-config   : ${MODE}"

# In manual mode the file has to exist before we spend time creating VMs.
if [[ "$MODE" == "manual" ]]; then
  [[ -f config/nodes-config.yaml ]] || die "$(printf '%s\n       %s' \
    "--manual-nodes-config was passed but config/nodes-config.yaml doesn't exist." \
    "Copy config/examples/nodes-config.yaml, fill it in, and re-run.")"
fi


# ======================
#  [1/4] vCenter login
# ======================

say_step 1 4 "Logging into vCenter"
say_dim "$GOVC_URL (datacenter: $GOVC_DATACENTER)"

# Prompts for $GOVC_USERNAME's password unless a cached session is still
# valid or VCENTER_PASSWORD is exported. See vcenter_login() in
# scripts/check-prereqs.sh.
vcenter_login


# ==========================
#  [2/4] Create the new VMs
# ==========================

say_step 2 4 "Creating VM(s) from config/new-nodes.csv"
echo "name,role,mac_mode,mac,ip,prefix,gateway,dns,cpu,memory_mb,disk_gb" > "$RESOLVED_CSV"

# Same vSphere extraConfig settings as install.sh, kept in sync with it:
#   disk.EnableUUID   - required for RHCOS disks to mount correctly on vSphere
#   stealclock.enable - lets the guest read the hypervisor's CPU steal time
#   tools.syncTime    - ONLY when there's no NTP server configured: makes
#                       VMware Tools sync the guest clock from the ESXi host
#                       instead, which satisfies the NTP validation without
#                       needing a real NTP server.
EXTRA_CONFIG_ARGS=(-e disk.EnableUUID=TRUE -e stealclock.enable=TRUE)
if [[ -z "${NTP_SERVERS:-}" ]]; then
  EXTRA_CONFIG_ARGS+=(-e tools.syncTime=TRUE)
  say_info "No NTP_SERVERS set: enabling tools.syncTime (VMware Tools host-to-guest clock sync)"
fi

grep -vE '^[[:space:]]*(#|$)' config/new-nodes.csv | tail -n +2 |
while IFS=',' read -r name role mac_mode mac ip prefix gateway dns cpu memory_mb disk_gb; do

  # Scoped strictly to our datacenter, so a same-named VM elsewhere in
  # vCenter can never cause a false "already exists".
  existing="$(govc find -dc="$GOVC_DATACENTER" / -type m -name "$name" 2>/dev/null || true)"

  if [[ -n "$existing" ]]; then
    say_warn "$name: already exists at '$existing', skipping create"
  else
    say_info "$name ${C_DIM}($role)${C_RESET}: creating ${cpu}vCPU / ${memory_mb}MB / ${disk_gb}GB"

    # Network adapter is always vmxnet3; MAC is only forced for mac_mode=fixed.
    net_args=(-net="$GOVC_NETWORK" -net.adapter=vmxnet3)
    if [[ "$mac_mode" == "fixed" ]]; then
      net_args+=(-net.address="$mac")
    fi

    # NOTE: extraConfig (-e) isn't a vm.create flag, only a vm.change one -
    # that's why it's applied separately right below, not here.
    govc vm.create \
      -dc="$GOVC_DATACENTER" \
      -pool="$GOVC_RESOURCE_POOL" \
      -ds="$GOVC_DATASTORE" \
      -folder="$GOVC_FOLDER" \
      -g=coreos64Guest \
      -firmware="${VM_FIRMWARE:-bios}" \
      -c="$cpu" \
      -m="$memory_mb" \
      -disk="${disk_gb}GB" \
      -disk.controller=pvscsi \
      "${net_args[@]}" \
      -on=false \
      "$name"
  fi

  # Applied via vm.change (the only govc subcommand that supports -e/
  # extraConfig), even if the VM already existed, so re-running this script
  # fixes VMs created before these settings (or NTP_SERVERS) were set.
  govc vm.change -vm="$name" "${EXTRA_CONFIG_ARGS[@]}"

  if [[ "$mac_mode" == "dynamic" ]]; then
    mac="$(govc device.info -vm="$name" ethernet-0 |
      sed -n 's/^[[:space:]]*MAC Address:[[:space:]]*//p' |
      tr -d ' \r')"

    [[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || die "invalid MAC '$mac' resolved for $name"
    say_dim "    resolved dynamic MAC: $mac"
  fi

  echo "$name,$role,$mac_mode,$mac,$ip,$prefix,$gateway,$dns,$cpu,$memory_mb,$disk_gb" >> "$RESOLVED_CSV"
done

say_ok "VM(s) ready. Resolved MAC per node:"
tail -n +2 "$RESOLVED_CSV" | awk -F',' -v d="$C_DIM" -v r="$C_RESET" '{printf "      %s%-12s%s %s\n", d, $1, r, $4}'


# =========================================
#  [3/4] Build day-2 ISO and boot the VM(s)
# =========================================

say_step 3 4 "Building day-2 discovery ISO and booting the new VM(s)"
rm -rf "$DAY2_DIR"
mkdir -p "$DAY2_DIR"

if [[ "$MODE" == "manual" ]]; then
  # Existence was already checked before the VMs were created.
  cp config/nodes-config.yaml "$DAY2_DIR/nodes-config.yaml"
  say_ok "Using your hand-written config/nodes-config.yaml as-is"
  say_dim "  make sure its macAddress values match the MACs listed above"
else
  # nodes-config.yaml uses the same per-host NMState schema as
  # agent-config.yaml's `hosts:` list (see install.sh step 3), just without
  # the apiVersion/metadata/rendezvousIP header - oc adm node-image create
  # only wants the hosts.
  {
    echo "hosts:"
  } > "$DAY2_DIR/nodes-config.yaml"

  tail -n +2 "$RESOLVED_CSV" | while IFS=',' read -r name role mac_mode mac ip prefix gateway dns cpu memory_mb disk_gb; do
    {
      echo "  - hostname: ${name}"
      echo "    interfaces:"
      echo "      - name: eth0"
      echo "        macAddress: ${mac}"
      echo "    networkConfig:"
      echo "      interfaces:"
      echo "        - name: eth0"
      echo "          type: ethernet"
      echo "          state: up"
      echo "          mac-address: ${mac}"
      echo "          ipv4:"
      echo "            enabled: true"
      echo "            dhcp: false"
      echo "            address:"
      echo "              - ip: ${ip}"
      echo "                prefix-length: ${prefix}"
      echo "      dns-resolver:"
      echo "        config:"
      echo "          server:"
      echo "$dns" | tr '|' '\n' | while read -r d; do echo "            - ${d}"; done
      echo "      routes:"
      echo "        config:"
      echo "          - destination: 0.0.0.0/0"
      echo "            next-hop-address: ${gateway}"
      echo "            next-hop-interface: eth0"
    } >> "$DAY2_DIR/nodes-config.yaml"
  done
  say_ok "nodes-config.yaml generated from $RESOLVED_CSV"
fi

oc adm node-image create --dir "$DAY2_DIR"
[[ -f "$DAY2_DIR/node.x86_64.iso" ]] || die "'oc adm node-image create' did not produce $DAY2_DIR/node.x86_64.iso"
say_ok "ISO built: $DAY2_DIR/node.x86_64.iso"

DEST_DIR="$(dirname "$DAY2_ISO_DATASTORE_PATH")"
if ! govc datastore.ls -ds="$GOVC_ISO_DATASTORE" "$DEST_DIR" >/dev/null 2>&1; then
  govc datastore.mkdir -ds="$GOVC_ISO_DATASTORE" -p "$DEST_DIR"
fi
govc datastore.upload -ds="$GOVC_ISO_DATASTORE" "$DAY2_DIR/node.x86_64.iso" "$DAY2_ISO_DATASTORE_PATH"

ISO_DS_NAME="$(basename "$GOVC_ISO_DATASTORE")"
ISO_REF="[$ISO_DS_NAME] $DAY2_ISO_DATASTORE_PATH"
say_ok "Uploaded to $ISO_REF"

tail -n +2 "$RESOLVED_CSV" | while IFS=',' read -r name role mac_mode mac ip prefix gateway dns cpu memory_mb disk_gb; do
  say_info "$name: attaching ISO and powering on"
  cdrom="$(govc device.ls -vm "$name" | awk '/^cdrom-/{print $1; exit}')"
  [[ -n "$cdrom" ]] || cdrom="$(govc device.cdrom.add -vm "$name")"
  govc device.cdrom.insert -vm "$name" -device "$cdrom" "$ISO_REF"
  govc vm.power -on "$name" >/dev/null
done


# ====================================
#  [4/4] Approve CSRs until nodes join
# ====================================

say_step 4 4 "Waiting for node CSR(s) and approving them"
say_dim "up to 30 minutes; new nodes need a couple of reboots before they report Ready"

new_names="$(tail -n +2 "$RESOLVED_CSV" | awk -F',' '{print $1}')"
deadline=$(( $(date +%s) + 1800 ))

while (( $(date +%s) < deadline )); do
  # A new node normally needs 2 CSRs approved (kubelet client, then kubelet
  # serving) before it's allowed to join; poll and approve whatever's
  # pending rather than assuming a fixed number of rounds.
  pending="$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true)"
  if [[ -n "$pending" ]]; then
    while read -r csr; do
      [[ -n "$csr" ]] || continue
      say_info "approving CSR $csr"
      oc adm certificate approve "$csr" >/dev/null
    done <<< "$pending"
  fi

  all_ready=true
  for n in $new_names; do
    status="$(oc get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "$status" == "True" ]] || all_ready=false
  done

  if [[ "$all_ready" == "true" ]]; then
    say_success "All new node(s) are Ready"
    for n in $new_names; do say_ok "$n"; done
    echo
    exit 0
  fi

  sleep 15
done

die "timed out after 30m waiting for new node(s) to become Ready: $new_names"
