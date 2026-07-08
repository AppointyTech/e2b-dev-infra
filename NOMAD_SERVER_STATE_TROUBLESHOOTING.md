# Nomad Server State Troubleshooting

This note documents the failure mode where Nomad clients are ready, but all Nomad jobs disappear.

## Symptom

Nomad is reachable and clients are registered:

```sh
nomad node status
```

But jobs are gone:

```sh
nomad job status
# No running jobs
```

External services then return errors like:

```txt
no healthy upstream
```

For example:

```sh
curl -i https://dashboard-api.e2b.quexio.com/health
```

may return `503` because the `dashboard-api` Nomad job no longer exists.

## Root Cause Found

The GCP regional managed instance group repaired the Nomad server VM because its health check marked the instance unhealthy.

The operation history showed:

```txt
operationType: compute.instances.repair.recreateInstance
statusMessage: Instance Group Manager 'e2b-orch-server-rig' initiated recreateInstance ...
Reason: Instance eligible for repair: instance unhealthy.
```

The server then rebooted and bootstrapped Nomad again:

```txt
Bootstrapping Nomad
Successfully applied node pool "api"
Successfully applied node pool "build"
```

That means Nomad started as a fresh single-server cluster. The startup script recreates bootstrap state and some node pools, but it does not recreate all Nomad jobs. Terraform owns those jobs, so they return only after running a Terraform apply.

## Why Jobs Disappear

Nomad server state is stored in the Nomad data directory. In this repo, `run-nomad.sh` starts Nomad with:

```sh
nomad agent -config $nomad_config_dir -data-dir $nomad_data_dir
```

The data directory defaults to:

```txt
/opt/nomad/data
```

See:

- `iac/provider-gcp/nomad-cluster/scripts/run-nomad.sh`

The Nomad server VM is managed by:

- `iac/provider-gcp/nomad-cluster/nodepool-control-server.tf`

Currently the server MIG has no stateful configuration. You can verify this with:

```sh
gcloud compute instance-groups managed describe e2b-orch-server-rig \
  --project=codefac \
  --region=us-central1 \
  --format='yaml(status.stateful,autoHealingPolicies,updatePolicy,currentActions)'
```

If it shows:

```yaml
status:
  stateful:
    hasStatefulConfig: false
```

then the MIG is not preserving per-instance state. This value is not written directly in the repo; it is a GCP-reported result of the MIG configuration. In the Terraform file, it happens because `google_compute_region_instance_group_manager.server_pool` does not define `stateful_disk` or per-instance stateful config.

## Read-Only Debug Commands

Check server VM timestamps:

```sh
gcloud compute instances list \
  --project=codefac \
  --filter='name~e2b-orch-server' \
  --format='table(name,zone,status,creationTimestamp,lastStartTimestamp)'
```

Check MIG state:

```sh
gcloud compute instance-groups managed describe e2b-orch-server-rig \
  --project=codefac \
  --region=us-central1 \
  --format='yaml(name,targetSize,currentActions,autoHealingPolicies,versions,status,updatePolicy)'
```

Check MIG instances:

```sh
gcloud compute instance-groups managed list-instances e2b-orch-server-rig \
  --project=codefac \
  --region=us-central1 \
  --format='table(instance,instanceStatus,currentAction,lastAttempt.errors.errors[].message,version.instanceTemplate)'
```

Check repair/update operations:

```sh
gcloud compute operations list \
  --project=codefac \
  --filter='targetLink~"e2b-orch-server" OR targetLink~"e2b-orch-server-rig" OR targetLink~"orch-server"' \
  --sort-by='~startTime' \
  --limit=50 \
  --format='table(name,operationType,status,startTime,endTime,targetLink,error.errors[].message)'
```

Describe a specific repair operation:

```sh
gcloud compute operations describe REPAIR_OPERATION_NAME \
  --project=codefac \
  --zone=us-central1-b \
  --format='yaml(name,operationType,status,startTime,endTime,targetLink,statusMessage,error,warnings)'
```

Check serial/startup logs:

```sh
gcloud compute instances get-serial-port-output e2b-orch-server-sv3d \
  --project=codefac \
  --zone=us-central1-b \
  --port=1 \
  --start=-30000
```

Check Nomad health check configuration:

```sh
gcloud compute health-checks describe e2b-orch-server-nomad-check \
  --project=codefac \
  --format='yaml(name,type,checkIntervalSec,timeoutSec,healthyThreshold,unhealthyThreshold,httpHealthCheck)'
```

## Recovery

If jobs disappear because the Nomad server was repaired, restore Terraform-managed jobs:

```sh
cd /Users/chandrashekhar29/appointy/e2b/e2b-dev-infra

make plan
make apply
```

Verify:

```sh
nomad job status
curl -i https://dashboard-api.e2b.quexio.com/health
```

## Will `SERVER_CLUSTER_SIZE=2` Fix It?

No, not reliably.

Nomad server state uses Raft. With 2 servers, quorum is still 2. If either server is down or being repaired, the cluster cannot make progress because only 1 of 2 voters remains.

That means a 2-server cluster can replicate state, but it does not give meaningful failure tolerance.

Use an odd number:

```txt
1 server  -> tolerates 0 server failures
2 servers -> tolerates 0 server failures
3 servers -> tolerates 1 server failure
5 servers -> tolerates 2 server failures
```

For a small but resilient setup, use:

```env
SERVER_CLUSTER_SIZE=3
```

This costs more, but it is the correct Raft shape.

## Solution Option 1: Relax Auto-Healing

File:

```txt
iac/provider-gcp/nomad-cluster/nodepool-control-server.tf
```

Current health check:

```hcl
resource "google_compute_health_check" "server_nomad_check" {
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 10 # 50 seconds

  http_health_check {
    request_path = "/v1/agent/health"
    port         = var.nomad_port
  }
}
```

For a minimal single-server dev cluster, relax it:

```hcl
resource "google_compute_health_check" "server_nomad_check" {
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 60 # 10 minutes

  http_health_check {
    request_path = "/v1/agent/health"
    port         = var.nomad_port
  }
}
```

Current auto-healing:

```hcl
auto_healing_policies {
  health_check      = google_compute_health_check.server_nomad_check.id
  initial_delay_sec = 120
}
```

Relax it:

```hcl
auto_healing_policies {
  health_check      = google_compute_health_check.server_nomad_check.id
  initial_delay_sec = 600
}
```

This does not preserve state by itself. It only reduces accidental repairs.

## Solution Option 2: Avoid Proactive Server Replacement In Dev

File:

```txt
iac/provider-gcp/nomad-cluster/nodepool-control-server.tf
```

Current update policy:

```hcl
update_policy {
  type           = var.environment == "dev" ? "PROACTIVE" : "OPPORTUNISTIC"
  minimal_action = "REPLACE"
  ...
}
```

For a single-server dev cluster, use:

```hcl
update_policy {
  type           = "OPPORTUNISTIC"
  minimal_action = "REPLACE"
  ...
}
```

This reduces Terraform/template-driven server replacements.

## Solution Option 3: Preserve Nomad State With Stateful Boot Disk

File:

```txt
iac/provider-gcp/nomad-cluster/nodepool-control-server.tf
```

Add stateful boot disk preservation inside:

```hcl
resource "google_compute_region_instance_group_manager" "server_pool" {
  ...

  stateful_disk {
    device_name = "persistent-disk-0"
    delete_rule = "NEVER"
  }

  ...
}
```

The current boot disk device name was observed from:

```sh
gcloud compute instances describe e2b-orch-server-sv3d \
  --project=codefac \
  --zone=us-central1-b \
  --format='yaml(disks)'
```

It showed:

```yaml
deviceName: persistent-disk-0
boot: true
type: PERSISTENT
autoDelete: true
```

After adding `stateful_disk`, verify the MIG reports:

```yaml
status:
  stateful:
    hasStatefulConfig: true
```

Important: adding stateful boot disk preservation may cause Terraform/GCP to update the MIG. Review `make plan` carefully before applying.

## Solution Option 4: Use 3 Nomad Servers

File:

```txt
.env.dev
```

Set:

```env
SERVER_CLUSTER_SIZE=3
```

This creates a proper Raft cluster that can tolerate one server failure.

Tradeoff: more VMs and cost.

## Recommended Path For Minimal Internal Hosting

For the current minimal setup:

1. Keep `SERVER_CLUSTER_SIZE=1` only if cost is the priority.
2. Relax server auto-healing thresholds.
3. Switch server update policy to `OPPORTUNISTIC`.
4. Add stateful boot disk preservation for the server MIG.
5. Run `make plan` and inspect for replacements.
6. Apply only after confirming the plan is acceptable.

For a more reliable setup:

1. Set `SERVER_CLUSTER_SIZE=3`.
2. Keep auto-healing enabled.
3. Still consider less aggressive health check thresholds.

