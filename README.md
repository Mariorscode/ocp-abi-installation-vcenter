<div align="center">

# OpenShift on vCenter — Agent-Based Installer

**Automated day-1 and day-2 provisioning of OpenShift 4.20 clusters on vCenter-hosted VMs, installed as bare metal.**

[![OpenShift](https://img.shields.io/badge/OpenShift-4.20-EE0000?logo=redhatopenshift&logoColor=white)](https://docs.openshift.com/container-platform/4.20/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html)
[![Installer](https://img.shields.io/badge/Installer-Agent--Based%20(ABI)-CC0000)](https://docs.openshift.com/container-platform/4.20/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html)
[![Platform](https://img.shields.io/badge/platform-baremetal%20on%20vCenter-0F80C1?logo=vmware&logoColor=white)](https://github.com/vmware/govmomi)
[![Shell](https://img.shields.io/badge/shell-Bash-4EAA25?logo=gnubash&logoColor=white)](scripts/)

</div>

# Installing an OCP cluster via ABI in vCenter

Scripts to install an OpenShift **4.20** cluster with the **Agent-Based
Installer (ABI)**, configured as **`platform: baremetal`**, on VMs hosted in
**vCenter**.

vCenter is used only as the hypervisor that creates and boots the VMs — the
installer never talks to vCenter as a cloud provider (no vSphere CSI/CCM, no
IPI-managed VMs). Node lifecycle (create VM, attach discovery ISO, power on)
is handled by these scripts through `govc`, the same way you would rack real
bare-metal hosts and boot them manually from an ISO.

**Key design points**

- **Static IPs everywhere** — no DHCP path in this repo.
- **MAC per node is `fixed` or `dynamic`** — you supply it, or vCenter
  assigns it and the script reads it back.
- **NIC is always VMXNET3**, disk controller always `pvscsi`.
- **No password is ever stored** — you're prompted once and a session token
  is cached (see [Variables → `vcenter-vars.env`](#1-configvcenter-varsenv--vcenter-connection)).
- **One directory per cluster** under `clusters/`, so several clusters can be
  installed from the same checkout.

---

## Requirements (bastion host)

Install these on whichever machine you run the scripts from:

| Tool                | Package / source                                                                                 | Needed by                          |
| ------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------- |
| `govc`              | [govmomi releases](https://github.com/vmware/govmomi/releases)                                   | both scripts                       |
| `openshift-install` | [console.redhat.com](https://console.redhat.com/openshift/install) — must match your OCP version | `install.sh`                       |
| `oc`                | same source, matching version                                                                    | `add-nodes.sh`                     |
| `envsubst`          | `gettext` package                                                                                | `install.sh`                       |
| `nmstatectl`        | `nmstate` package                                                                                | `install.sh` in **auto** mode only |

> [!NOTE]
> **`nmstatectl` is easy to miss.** `openshift-install` shells out to it
> *locally* to validate the static network config it embeds in the ISO.
> Without it, ISO generation fails with
> `nmstatectl: executable file not found in $PATH`.

Verify everything at once:

```sh
scripts/check-prereqs.sh
```

You also need, reachable from the cluster network:

- **DNS records** — `api.<CLUSTER_NAME>.<BASE_DOMAIN>` → `API_VIP`, and
  `*.apps.<CLUSTER_NAME>.<BASE_DOMAIN>` → `INGRESS_VIP`. The install cannot
  finish without them.
- **Two free IPs** inside `MACHINE_NETWORK_CIDR` for those VIPs.

---

# Using Scripts

Three scripts, all run from the repo root:

| Script                     | Purpose                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------- |
| `scripts/check-prereqs.sh` | Verifies required CLI tools. Also the shared library the other two source.              |
| `scripts/install.sh`       | **Day 1** — creates VMs, renders configs, builds/uploads ISO, boots, waits for install. |
| `scripts/add-nodes.sh`     | **Day 2** — adds worker nodes to an already-installed cluster.                          |

### Quick reference

```sh
scripts/check-prereqs.sh                     # check tools
scripts/install.sh                           # install a cluster (auto config)
scripts/install.sh --manual-agent-config     # install using your own agent-config.yaml
scripts/add-nodes.sh                         # add workers (auto config)
scripts/add-nodes.sh --manual-nodes-config   # add workers using your own nodes-config.yaml
```

---

## 1. Pre-checks before installation

`scripts/check-prereqs.sh`

```sh
scripts/check-prereqs.sh
```

Takes no arguments. Prints a pass/fail table for every tool and exits `1` if
any is missing.

It doubles as the repo's **shared shell library**: `install.sh` and
`add-nodes.sh` source it for the colour/log helpers (`say_step`, `say_ok`,
`die`, …), for `require_tools`, and for `vcenter_login`. Sourcing it defines
functions only — it runs no checks and doesn't change the caller's shell
options.

Colours are dropped automatically when stdout isn't a TTY or when `NO_COLOR`
is set, so piping to a file stays clean.

---

## 2. `scripts/install.sh` — day 1

### Preparation

```sh
# 1. Copy the templates (the copies are gitignored)
cp config/examples/vcenter-vars.env config/vcenter-vars.env
cp config/examples/cluster-vars.env config/cluster-vars.env
cp config/examples/nodes.csv        config/nodes.csv

# 2. Edit those three files — see the Variables section below

# 3. Add your two secrets at the paths cluster-vars.env points to
#    (download the pull secret from console.redhat.com/openshift/install/pull-secret)
cp ~/Downloads/pull-secret.json config/pull-secret.json
cp ~/.ssh/id_ed25519.pub        config/ssh-key.pub
```

### Run

```sh
scripts/install.sh
```

You'll be prompted once for the vCenter password of `GOVC_USERNAME`.

### What it does, step by step

| Step    | Action                                                                                                                                                   |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1/6** | Logs into vCenter (prompt / cached token / `$VCENTER_PASSWORD`).                                                                                         |
| **2/6** | Creates one VM per row of `config/nodes.csv`, applies the vSphere `extraConfig` settings, resolves dynamic MACs, and writes `config/nodes.resolved.csv`. |
| **3/6** | Renders `config/install-config.yaml` from the template, and `config/agent-config.yaml` from the resolved CSV (auto mode only).                           |
| **4/6** | Builds the discovery ISO into `clusters/<INSTALL_DIR>/`.                                                                                                 |
| **5/6** | Uploads the ISO to `GOVC_ISO_DATASTORE`, attaches it as a CD-ROM to every VM and powers them on.                                                         |
| **6/6** | Waits for `bootstrap-complete`, then `install-complete`. Prints the kubeconfig path and console URL.                                                     |

Expect **40–60 minutes** in step 6.

### Auto vs. manual `agent-config.yaml`

|                                    | **Auto** (default)                | **Manual** (`--manual-agent-config`)                                                         |
| ---------------------------------- | --------------------------------- | -------------------------------------------------------------------------------------------- |
| Command                            | `scripts/install.sh`              | `scripts/install.sh --manual-agent-config`                                                   |
| `agent-config.yaml`                | Generated from `config/nodes.csv` | You write `config/agent-config.yaml`                                                         |
| Needs `nmstatectl`                 | **Yes**                           | No                                                                                           |
| VMs still created from `nodes.csv` | Yes                               | Yes                                                                                          |
| Use it when                        | Normal case                       | You want DHCP for some hosts, bonds/VLANs, or any NMState option the generator doesn't cover |

**Manual workflow** — you need the real MACs first, so run it twice:

```sh
# 1st run: creates the VMs, prints each node's resolved MAC, then stops
#          because config/agent-config.yaml doesn't exist yet
scripts/install.sh --manual-agent-config

# 2nd: write the file using those MACs, then re-run
cp config/examples/agent-config.yaml config/agent-config.yaml
$EDITOR config/agent-config.yaml
scripts/install.sh --manual-agent-config
```

### Re-running

Safe to re-run. Existing VMs are detected with `govc find` scoped to your
exact `GOVC_DATACENTER` and skipped (the matched inventory path is printed),
while `extraConfig` settings are re-applied to every VM either way.

> [!WARNING]
>  Step 4 does `rm -rf clusters/<INSTALL_DIR>` before rebuilding. Re-running
> a **completed** install therefore destroys that cluster's `auth/kubeconfig`.
> Back it up first if you still need it.

---

## 3. `scripts/add-nodes.sh` — day 2

Adds **worker** nodes to a cluster that is already installed. Control-plane
nodes are rejected up front — that flow isn't supported here.

### Preparation

```sh
cp config/examples/new-nodes.csv config/new-nodes.csv
$EDITOR config/new-nodes.csv     # list ONLY the new machines
```

Same schema as `nodes.csv`. Reuses `vcenter-vars.env` and `cluster-vars.env`
unchanged.

### Run

```sh
scripts/add-nodes.sh
```

### What it does, step by step

| Step    | Action                                                                                                                            |
| ------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **1/4** | Logs into vCenter.                                                                                                                |
| **2/4** | Creates the new VM(s) from `config/new-nodes.csv`, resolves MACs, writes `config/new-nodes.resolved.csv`.                         |
| **3/4** | Builds `nodes-config.yaml`, runs `oc adm node-image create` against the running cluster, uploads the ISO and boots the new VM(s). |
| **4/4** | Polls and approves node CSRs until every new node reports `Ready` (30 min timeout).                                               |

### Auto vs. manual `nodes-config.yaml`

Mirrors the day-1 choice:

```sh
scripts/add-nodes.sh                        # generated from new-nodes.csv
scripts/add-nodes.sh --manual-nodes-config  # uses your config/nodes-config.yaml
```

In manual mode the file's existence is checked **before** any VM is created,
so a missing file fails instantly instead of leaving half-provisioned VMs.

>[!NOTE]
> `nodes-config.yaml` is **only** the `hosts:` list — no
> `apiVersion`/`metadata`/`rendezvousIP` header, unlike `agent-config.yaml`.

### Which cluster does it target?

It resolves `clusters/<INSTALL_DIR>/auth/kubeconfig` from `cluster-vars.env`.
Override for a cluster outside this layout:

```sh
KUBECONFIG=/path/to/kubeconfig scripts/add-nodes.sh
```

---

## Multiple clusters from one checkout

Everything a run generates lives under `clusters/<INSTALL_DIR>/`. To install
a second cluster, point `cluster-vars.env` at a different `CLUSTER_NAME` /
`INSTALL_DIR` (and a different `nodes.csv`) and run `install.sh` again — the
first cluster's manifests, ISO and kubeconfig are untouched.

```
clusters/
  ocp4-abi/          install-config.yaml  agent-config.yaml
                     agent.x86_64.iso     auth/kubeconfig
                     day2-nodes/
  ocp4-lab/          ...
```

---

# Variables

Files you create live in `config/` and are **gitignored**; the versioned
templates are in `config/examples/`.

| You create                 | Copy from                           | Used by                                   |
| -------------------------- | ----------------------------------- | ----------------------------------------- |
| `config/vcenter-vars.env`  | `config/examples/vcenter-vars.env`  | both                                      |
| `config/cluster-vars.env`  | `config/examples/cluster-vars.env`  | both                                      |
| `config/nodes.csv`         | `config/examples/nodes.csv`         | `install.sh`                              |
| `config/new-nodes.csv`     | `config/examples/new-nodes.csv`     | `add-nodes.sh`                            |
| `config/pull-secret.json`  | console.redhat.com                  | `install.sh`                              |
| `config/ssh-key.pub`       | your `~/.ssh`                       | `install.sh`                              |
| `config/agent-config.yaml` | `config/examples/agent-config.yaml` | `install.sh --manual-agent-config` only   |
| `config/nodes-config.yaml` | `config/examples/nodes-config.yaml` | `add-nodes.sh --manual-nodes-config` only |

Generated for you — **never edit by hand**, they're overwritten every run:
`config/install-config.yaml`, `config/nodes.resolved.csv`,
`config/new-nodes.resolved.csv`, and everything under `clusters/`.

---

## 1. `config/vcenter-vars.env` — vCenter connection

| Variable                     | Required | Example                               | Description                                                                                |
| ---------------------------- | -------- | ------------------------------------- | ------------------------------------------------------------------------------------------ |
| `GOVC_URL`                   | ✅        | `vcenter.example.local`               | vCenter API endpoint. No scheme, no trailing slash.                                        |
| `GOVC_USERNAME`              | ✅        | `svc-openshift@vsphere.local`         | Account used at login. Prefer a least-privilege service account.                           |
| `GOVC_INSECURE`              | ✅        | `false`                               | `true` \| `false`. Skip TLS verification. Use `false` + `GOVC_TLS_CA_CERTS` outside a lab. |
| `GOVC_TLS_CA_CERTS`          | —        | `/path/to/ca.pem`                     | CA bundle when `GOVC_INSECURE="false"` and the cert is internally signed.                  |
| `GOVC_DATACENTER`            | ✅        | `Datacenter1`                         | Datacenter holding the VMs. Must match **exactly** (case-sensitive).                       |
| `GOVC_CLUSTER`               | ✅        | `Cluster1`                            | Compute cluster.                                                                           |
| `GOVC_RESOURCE_POOL`         | ✅        | `Resources`                           | Resource pool the VMs are placed in.                                                       |
| `GOVC_DATASTORE`             | ✅        | `datastore1`                          | Datastore for the **VM disks**.                                                            |
| `GOVC_ISO_DATASTORE`         | ✅        | `datastore-isos`                      | Datastore for **ISO uploads** — see note below.                                            |
| `GOVC_NETWORK`               | ✅        | `VM Network`                          | Port group the VMXNET3 NIC attaches to.                                                    |
| `GOVC_FOLDER`                | ✅        | `ocp4`                                | VM folder for the cluster's VMs.                                                           |
| `VCENTER_ISO_DATASTORE_PATH` | ✅        | `ocp4-agent-iso/agent.x86_64.iso`     | Path **including filename** inside `GOVC_ISO_DATASTORE` for the day-1 ISO.                 |
| `DAY2_ISO_DATASTORE_PATH`    | ✅        | `ocp4-agent-iso/day2/node.x86_64.iso` | Same, for the day-2 ISO.                                                                   |
| `GOVC_HOME`                  | ✅        | `.govc`                               | Where the session token is cached. Keep it inside the repo (gitignored).                   |

**Inventory paths.** Every `GOVC_*` inventory variable accepts a bare name or
a full path, useful when names aren't unique:

```sh
GOVC_DATASTORE="datastore1"
GOVC_DATASTORE="/Datacenter1/datastore/DS Group/datastore1"
```

**Password** — never in this file. Resolution order:

1. Valid cached session in `GOVC_HOME` → nothing asked (vCenter idles at ~30 min).
2. `$VCENTER_PASSWORD` → non-interactive.
3. Interactive prompt on the terminal, 3 attempts, input not echoed.

---

## 2. `config/cluster-vars.env` — cluster & network

| Variable                      | Required | Example                   | Description                                                                                        |
| ----------------------------- | -------- | ------------------------- | -------------------------------------------------------------------------------------------------- |
| `CLUSTER_NAME`                | ✅        | `ocp4-abi`                | Cluster name. Becomes part of every FQDN.                                                          |
| `BASE_DOMAIN`                 | ✅        | `example.com`             | Base DNS domain. **Must not already contain `CLUSTER_NAME`.**                                      |
| `OCP_VERSION`                 | ✅        | `4.20.0`                  | Release being installed. Your `openshift-install` binary must match.                               |
| `MACHINE_NETWORK_CIDR`        | ✅        | `192.0.2.0/24`            | Subnet the nodes live on.                                                                          |
| `API_VIP`                     | ✅        | `192.0.2.5`               | Virtual IP for the API. Free address inside `MACHINE_NETWORK_CIDR`.                                |
| `INGRESS_VIP`                 | ✅        | `192.0.2.6`               | Virtual IP for ingress. Free address inside `MACHINE_NETWORK_CIDR`.                                |
| `CLUSTER_NETWORK_CIDR`        | ✅        | `10.128.0.0/14`           | Pod network. OpenShift default; change only on collision.                                          |
| `CLUSTER_NETWORK_HOST_PREFIX` | ✅        | `23`                      | Subnet size per node inside the pod network.                                                       |
| `SERVICE_NETWORK_CIDR`        | ✅        | `172.30.0.0/16`           | Service network. OpenShift default.                                                                |
| `RENDEZVOUS_IP`               | ✅        | `192.0.2.10`              | IP of the node coordinating the install. **Must equal the `ip` of a `master` row in `nodes.csv`.** |
| `NTP_SERVERS`                 | —        | `192.0.2.2\|192.0.2.7`    | NTP servers, `\|`-separated. **Leave unset** if you have none — see below.                         |
| `PULL_SECRET_FILE`            | ✅        | `config/pull-secret.json` | Path to the Red Hat pull secret.                                                                   |
| `SSH_PUBLIC_KEY_FILE`         | ✅        | `config/ssh-key.pub`      | Public key injected for `core@` SSH access to the nodes.                                           |
| `INSTALL_DIR`                 | —        | `ocp4-abi`                | Directory name under `clusters/`. Defaults to `CLUSTER_NAME`.                                      |

**The `BASE_DOMAIN` trap.** The API FQDN is built as
`api.<CLUSTER_NAME>.<BASE_DOMAIN>`. Setting `CLUSTER_NAME="optimus"` **and**
`BASE_DOMAIN="optimus.example.com"` produces
`api.optimus.optimus.example.com`. Use `BASE_DOMAIN="example.com"`.

**`NTP_SERVERS` is optional and controls VM clock behaviour:**

| `NTP_SERVERS`       | Behaviour                                                                                                                                                                          |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Unset** (default) | Scripts add `tools.syncTime=TRUE` to every VM. Nodes take their clock from the ESXi host via VMware Tools — no NTP server needed, and the installer's NTP validation still passes. |
| **Set**             | Written to `agent-config.yaml` as `additionalNTPSources`. `tools.syncTime` is deliberately **not** set, so VMware Tools doesn't fight chrony over the clock.                       |

---

## 3. `config/nodes.csv` and `config/new-nodes.csv` — machine specs

One row per VM. The header row is mandatory and must match **exactly**;
`#` comments and blank lines are ignored.

```csv
name,role,mac_mode,mac,ip,prefix,gateway,dns,cpu,memory_mb,disk_gb
master-0,master,fixed,00:50:56:00:00:01,192.0.2.10,24,192.0.2.1,192.0.2.2|192.0.2.3,8,16384,120
worker-0,worker,dynamic,,192.0.2.13,24,192.0.2.1,192.0.2.2|192.0.2.3,8,16384,120
```

| Column      | Options / format       | Description                                                                 |
| ----------- | ---------------------- | --------------------------------------------------------------------------- |
| `name`      | e.g. `master-0`        | VM name in vCenter **and** node hostname. Must be unique in the datacenter. |
| `role`      | `master` \| `worker`   | `new-nodes.csv` accepts **`worker` only**.                                  |
| `mac_mode`  | `fixed` \| `dynamic`   | Where the MAC comes from — see below.                                       |
| `mac`       | `00:50:56:00:00:01`    | **Required** if `mac_mode=fixed`; **leave empty** if `dynamic`.             |
| `ip`        | `192.0.2.10`           | Static IP. Always required — no DHCP.                                       |
| `prefix`    | `24`                   | Netmask length.                                                             |
| `gateway`   | `192.0.2.1`            | Default gateway.                                                            |
| `dns`       | `192.0.2.2\|192.0.2.3` | One or more DNS servers, `\|`-separated. Per node.                          |
| `cpu`       | `8`                    | vCPU count. Control plane: 4 minimum, 8 recommended.                        |
| `memory_mb` | `16384`                | RAM in **MB**. Control plane: 16384 minimum.                                |
| `disk_gb`   | `120`                  | OS disk size in **GB**. 100 minimum.                                        |

**`mac_mode`:**

| Value     | `mac` column | Behaviour                                                                                                                 |
| --------- | ------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `fixed`   | Required     | Set on the VM's NIC at creation. Use when MACs are pre-registered (DHCP reservations, NAC, firewall rules).               |
| `dynamic` | Empty        | vCenter/ESXi assigns it; the script reads it back and records it in `nodes.resolved.csv`, then binds the static IP to it. |

Either way the real MAC ends up in `config/nodes.resolved.csv`, which is what
generates `agent-config.yaml` — not the original CSV.

**Cluster sizing.** Replica counts are derived from the rows actually
created, not hardcoded: use 3 `master` rows (or 1 for SNO), plus however many
`worker` rows you want.

---

## 4. Manual config files (optional)

Only needed with the `--manual-*` flags.

| File                       | Flag                                 | Shape                                                      |
| -------------------------- | ------------------------------------ | ---------------------------------------------------------- |
| `config/agent-config.yaml` | `install.sh --manual-agent-config`   | `apiVersion` + `metadata.name` + `rendezvousIP` + `hosts:` |
| `config/nodes-config.yaml` | `add-nodes.sh --manual-nodes-config` | `hosts:` **only**                                          |

In both, each host's `macAddress` must match the MAC actually assigned to its
VM — run the script once first to have them printed. Omitting a host's
`networkConfig` block entirely makes that host use DHCP, and then
`nmstatectl` isn't needed for it.

---

## VM hardware settings applied automatically

Set on every VM via `govc vm.change` at creation **and** on every re-run:

| Setting                  | When                             | Why                                                                                                                             |
| ------------------------ | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `disk.EnableUUID=TRUE`   | Always                           | RHCOS needs a stable disk UUID to mount the root disk. Missing it fails host validation with *"disk.EnableUUID isn't enabled"*. |
| `stealclock.enable=TRUE` | Always                           | Lets the guest read the hypervisor's CPU steal-time counter (Red Hat recommendation for OpenShift on vSphere).                  |
| `tools.syncTime=TRUE`    | Only when `NTP_SERVERS` is unset | Clock from the ESXi host instead of an NTP server.                                                                              |

> On a VM that already existed **and was already powered on**, a changed
> setting is written but only applies after a full power cycle:
> `govc vm.power -reboot -force=true <name>`.


---

## Author

**Mario Rodríguez Serrano** — [LinkedIn](https://www.linkedin.com/in/mario-rodriguez-serrano/) · [GitHub](https://github.com/Mariorscode)
