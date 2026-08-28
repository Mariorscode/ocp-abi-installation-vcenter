#!/usr/bin/env bash
# Day-1: creates the cluster VMs in vCenter, renders install-config.yaml
# (always) and agent-config.yaml (unless --manual-agent-config is passed),
# builds the Agent-Based Installer discovery ISO, boots the VMs from it and
# waits for the install to finish.
#
# Usage:
#   scripts/install.sh                         # auto-generate agent-config.yaml (needs nmstatectl)
#   scripts/install.sh --manual-agent-config   # you already wrote config/agent-config.yaml yourself
#
# Everything this run produces lives under clusters/<cluster>/ so several
# clusters can be installed from the same checkout without clobbering
# each other.


# ======================
#  PRE-RUN set defaults
# ======================

set -euo pipefail
# Set default directory as the parent directory of the script's location
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Colour/log helpers (say_step, say_ok, die, ...) and require_tools() live in
# check-prereqs.sh so this script and add-nodes.sh share one implementation.
source scripts/check-prereqs.sh

# --manual-agent-config switches off auto-generation of agent-config.yaml in
# step 3 below; everything else (VM creation, install-config.yaml, ISO build
# and boot) runs the same either way.
MODE="auto"
if [[ "${1:-}" == "--manual-agent-config" ]]; then
  MODE="manual"
elif [[ -n "${1:-}" ]]; then
  die "unknown option '$1' (only --manual-agent-config is supported)"
fi

say_banner "OpenShift Agent-Based Install on vCenter"


# ======================
#  PRE-RUN validation
# ======================

# Fail fast on missing tools rather than partway through the run.
# nmstatectl is only needed in auto mode: openshift-install shells out to it
# locally to validate the static network config generated in step 3.
if [[ "$MODE" == "auto" ]]; then
  require_tools govc openshift-install envsubst nmstatectl
else
  require_tools govc openshift-install envsubst
fi

# These 3 files are the only ones you're expected to hand-edit before running this script, everything else under config/ gets generated.
[[ -f config/vcenter-vars.env ]] || die "missing config/vcenter-vars.env (cp config/examples/vcenter-vars.env config/vcenter-vars.env)"
[[ -f config/cluster-vars.env ]] || die "missing config/cluster-vars.env (cp config/examples/cluster-vars.env config/cluster-vars.env)"
[[ -f config/nodes.csv ]]        || die "missing config/nodes.csv (cp config/examples/nodes.csv config/nodes.csv)"

# `set -a` exports every variable sourced from these two files automatically
# (GOVC_*, CLUSTER_NAME, NTP_SERVERS, etc.) so govc and the rest of this
# script can see them without listing each one individually.
set -a
source config/vcenter-vars.env
source config/cluster-vars.env
set +a
mkdir -p "$GOVC_HOME"

[[ -f "$PULL_SECRET_FILE" ]]    || die "missing $PULL_SECRET_FILE"
[[ -f "$SSH_PUBLIC_KEY_FILE" ]] || die "missing $SSH_PUBLIC_KEY_FILE"

# Every cluster gets its own directory under clusters/, named after
# INSTALL_DIR (or the cluster name if unset). Keeping them side by side means
# a second cluster installed from this same checkout never overwrites the
# first one's manifests, ISO or kubeconfig.
CLUSTERS_ROOT="clusters"
INSTALL_DIR="$CLUSTERS_ROOT/${INSTALL_DIR:-$CLUSTER_NAME}"
RESOLVED_CSV="config/nodes.resolved.csv"

say_info "Cluster       : ${C_BOLD}${CLUSTER_NAME}.${BASE_DOMAIN}${C_RESET}"
say_info "Cluster dir   : ${INSTALL_DIR}"
say_info "agent-config  : ${MODE}"


# ======================
#  [1/6] vCenter login
# ======================

say_step 1 6 "Logging into vCenter"
say_dim "$GOVC_URL (datacenter: $GOVC_DATACENTER)"

# Prompts for the password of $GOVC_USERNAME (unless a cached session is
# still valid, or VCENTER_PASSWORD is exported) and exchanges it for a
# session token cached under $GOVC_HOME. Every govc call below reuses that
# token - the password itself is used exactly once, here. See vcenter_login()
# in scripts/check-prereqs.sh.
vcenter_login


# ======================
#  [2/6] Create the VMs
# ======================

say_step 2 6 "Creating VMs from config/nodes.csv"
echo "name,role,mac_mode,mac,ip,prefix,gateway,dns,cpu,memory_mb,disk_gb" > "$RESOLVED_CSV"

# Set special variables on VMs due to VMware Tools and clock sync issues.
# If NTP_SERVERS is unset, we enable tools.syncTime to keep the guest clock
# in sync with the ESXi host instead of a real NTP server.
EXTRA_CONFIG_ARGS=(-e disk.EnableUUID=TRUE -e stealclock.enable=TRUE)
if [[ -z "${NTP_SERVERS:-}" ]]; then
  EXTRA_CONFIG_ARGS+=(-e tools.syncTime=TRUE)
  say_info "No NTP_SERVERS set: enabling tools.syncTime (VMware Tools host-to-guest clock sync)"
fi

# Read each node from the CSV, skipping comments, empty lines and the header.
grep -vE '^[[:space:]]*(#|$)' config/nodes.csv | tail -n +2 |
while IFS=',' read -r name role mac_mode mac ip prefix gateway dns cpu memory_mb disk_gb; do

  # Check whether the VM already exists in the target datacenter.
  existing="$(govc find -dc="$GOVC_DATACENTER" / -type m -name "$name" 2>/dev/null || true)"

  if [[ -n "$existing" ]]; then
    say_warn "$name: already exists at '$existing', skipping create"
  else
    say_info "$name ${C_DIM}($role)${C_RESET}: creating ${cpu}vCPU / ${memory_mb}MB / ${disk_gb}GB"

    # Use vmxnet3; only set a fixed MAC when requested.
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

  # Apply extra VM settings to both new and existing VMs, so re-running this
  # script also fixes VMs created before these settings existed. On an
  # already-powered-on VM the value is written but only takes effect after a
  # full power cycle.
  govc vm.change -vm="$name" "${EXTRA_CONFIG_ARGS[@]}"

  # Read the MAC assigned by vCenter for dynamically configured NICs.
  # sed, not awk -F':', because the value itself contains colons.
  if [[ "$mac_mode" == "dynamic" ]]; then
    mac="$(govc device.info -vm="$name" ethernet-0 |
      sed -n 's/^[[:space:]]*MAC Address:[[:space:]]*//p' |
      tr -d ' \r')"

    [[ "$mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || die "invalid MAC '$mac' resolved for $name"
    say_dim "    resolved dynamic MAC: $mac"
  fi

  # Save the final node configuration, including the actual MAC address.
  # This resolved file, not the original nodes.csv, is what step 3 reads.
  echo "$name,$role,$mac_mode,$mac,$ip,$prefix,$gateway,$dns,$cpu,$memory_mb,$disk_gb" >> "$RESOLVED_CSV"

done

say_ok "VMs ready. Resolved MAC per node:"
tail -n +2 "$RESOLVED_CSV" | awk -F',' -v d="$C_DIM" -v r="$C_RESET" '{printf "      %s%-12s%s %s\n", d, $1, r, $4}'
say_dim "  (use these if you hand-write agent-config.yaml for --manual-agent-config)"


# ==================================
#  [3/6] Render the install configs
# ==================================

say_step 3 6 "Rendering install-config.yaml${C_RESET}${C_DIM} (agent-config mode: $MODE)"

# controlPlane/compute replica counts come from what actually got created in
# step 2, not from counting config/nodes.csv - keeps this correct even if a
# row failed to create or an existing VM was skipped.
CONTROL_PLANE_COUNT=$(tail -n +2 "$RESOLVED_CSV" | awk -F',' '$2=="master"' | wc -l | tr -d ' ')
WORKER_COUNT=$(tail -n +2 "$RESOLVED_CSV" | awk -F',' '$2=="worker"' | wc -l | tr -d ' ')
[[ "$CONTROL_PLANE_COUNT" -ge 1 ]] || die "no role=master rows in $RESOLVED_CSV"

# install-config.yaml template has ${VAR} placeholders for everything below;
# envsubst does the substitution. PULL_SECRET/SSH_PUBLIC_KEY are read from
# the files cluster-vars.env points at, not typed anywhere.
export CLUSTER_NAME BASE_DOMAIN MACHINE_NETWORK_CIDR API_VIP INGRESS_VIP \
       CLUSTER_NETWORK_CIDR CLUSTER_NETWORK_HOST_PREFIX SERVICE_NETWORK_CIDR \
       CONTROL_PLANE_COUNT WORKER_COUNT
export PULL_SECRET="$(tr -d '\n' < "$PULL_SECRET_FILE")"
export SSH_PUBLIC_KEY="$(tr -d '\n' < "$SSH_PUBLIC_KEY_FILE")"
envsubst < config/examples/install-config.yaml > config/install-config.yaml
say_ok "install-config.yaml: $CONTROL_PLANE_COUNT control-plane, $WORKER_COUNT worker"

# Installation set as agent-config manual, so we don't generate it, but we do check that the user has provided it.
if [[ "$MODE" == "manual" ]]; then
  # Nothing to generate: just make sure the user actually put a file there.
  [[ -f config/agent-config.yaml ]] || die "$(printf '%s\n       %s' \
    "--manual-agent-config was passed but config/agent-config.yaml doesn't exist." \
    "Copy config/examples/agent-config.yaml, fill it in, and re-run.")"
  say_ok "Using your hand-written config/agent-config.yaml as-is"
else
  # Installation set as agent-config auto, so we generate it from the resolved
  # CSV. This requires nmstatectl to validate the static network config.
  {
    echo "apiVersion: v1alpha1"
    echo "metadata:"
    echo "  name: ${CLUSTER_NAME}"
    echo "rendezvousIP: ${RENDEZVOUS_IP}"
    echo "hosts:"
  } > config/agent-config.yaml

  # ...then one `hosts:` entry per node, in NMState format, giving each host
  # a static IP bound to its MAC address (this is the part that requires
  # nmstatectl to validate).
  tail -n +2 "$RESOLVED_CSV" | while IFS=',' read -r name role mac_mode mac ip prefix gateway dns cpu memory_mb disk_gb; do
    {
      echo "  - hostname: ${name}"
      echo "    role: ${role}"
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
      # dns column supports multiple servers separated by "|"; one YAML
      # list item per server.
      echo "$dns" | tr '|' '\n' | while read -r d; do echo "            - ${d}"; done
      echo "      routes:"
      echo "        config:"
      echo "          - destination: 0.0.0.0/0"
      echo "            next-hop-address: ${gateway}"
      echo "            next-hop-interface: eth0"
    } >> config/agent-config.yaml
  done
  say_ok "agent-config.yaml generated from $RESOLVED_CSV"
fi


# ==============================
#  [4/6] Build the discovery ISO
# ==============================

say_step 4 6 "Building discovery ISO"
say_dim "$INSTALL_DIR"

# openshift-install only reads install-config.yaml/agent-config.yaml from
# its --dir, so they're copied in fresh each run (rm -rf avoids mixing in
# any manifests left over from a previous, different attempt).
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp config/install-config.yaml "$INSTALL_DIR/install-config.yaml"
cp config/agent-config.yaml "$INSTALL_DIR/agent-config.yaml"
openshift-install agent create image --dir "$INSTALL_DIR" --log-level=info
say_ok "ISO built: $INSTALL_DIR/agent.x86_64.iso"


# =====================================
#  [5/6] Upload the ISO and boot the VMs
# =====================================

say_step 5 6 "Uploading ISO to vCenter and booting VMs"
DEST_DIR="$(dirname "$VCENTER_ISO_DATASTORE_PATH")"

# Do NOT swallow mkdir errors here: if this silently fails, the upload
# below gets "405 Method Not Allowed" instead of a clear error, because
# vSphere's HTTP PUT returns 405 (not 404) when the target folder is
# missing. Uses GOVC_ISO_DATASTORE, not GOVC_DATASTORE: the account may
# not have upload rights on the datastore used for VM disks.
if ! govc datastore.ls -ds="$GOVC_ISO_DATASTORE" "$DEST_DIR" >/dev/null 2>&1; then
  govc datastore.mkdir -ds="$GOVC_ISO_DATASTORE" -p "$DEST_DIR"
fi
govc datastore.upload -ds="$GOVC_ISO_DATASTORE" "$INSTALL_DIR/agent.x86_64.iso" "$VCENTER_ISO_DATASTORE_PATH"

# vSphere's "[datastore] path" bracket notation wants the bare datastore
# name, not its full inventory path (which GOVC_ISO_DATASTORE may be).
ISO_DS_NAME="$(basename "$GOVC_ISO_DATASTORE")"
ISO_REF="[$ISO_DS_NAME] $VCENTER_ISO_DATASTORE_PATH"
say_ok "Uploaded to $ISO_REF"

tail -n +2 "$RESOLVED_CSV" | while IFS=',' read -r name role mac_mode mac ip prefix gateway dns cpu memory_mb disk_gb; do
  say_info "$name: attaching ISO and powering on"
  # Reuse an existing CD-ROM device if the VM already has one (e.g. a
  # previous run already added it); only create a new one if none exists.
  cdrom="$(govc device.ls -vm "$name" | awk '/^cdrom-/{print $1; exit}')"
  [[ -n "$cdrom" ]] || cdrom="$(govc device.cdrom.add -vm "$name")"
  govc device.cdrom.insert -vm "$name" -device "$cdrom" "$ISO_REF"
  govc vm.power -on "$name" >/dev/null
done


# =================================
#  [6/6] Wait for the install to end
# =================================

say_step 6 6 "Waiting for bootstrap and install to complete"
say_dim "this usually takes 40-60 minutes"

# Blocks until the temporary bootstrap node hands off control to the real
# control plane, then until the whole cluster reports itself installed.
openshift-install agent wait-for bootstrap-complete --dir "$INSTALL_DIR" --log-level=info
openshift-install agent wait-for install-complete --dir "$INSTALL_DIR" --log-level=info

say_success "Cluster ready"
say_info "kubeconfig : ${C_BOLD}$INSTALL_DIR/auth/kubeconfig${C_RESET}"
say_info "console    : https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
say_dim   "  export KUBECONFIG=$(pwd)/$INSTALL_DIR/auth/kubeconfig"
echo
