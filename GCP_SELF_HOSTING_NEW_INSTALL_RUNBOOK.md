# E2B GCP Self-Hosting Runbook - New Installation

This document captures the successful clean installation of the open source E2B stack on GCP using:

- GCP project: `codefac`
- Region: `us-central1`
- Base domain: `e2b.quexio.com`
- Prefix: `e2b-`
- Postgres database: `e2b_cf`
- Terraform environment: `dev`

Secrets, tokens, API keys, and database passwords are intentionally omitted.

## Final Endpoints

After the successful install, the expected public endpoints are:

```text
https://api.e2b.quexio.com
https://nomad.e2b.quexio.com
https://dashboard-api.e2b.quexio.com
*.e2b.quexio.com
```

The wildcard domain is used for sandbox routing.

## Important Config Choices

The important `.env.dev` choices for the new installation were:

```sh
GCP_PROJECT_ID=codefac
GCP_REGION=us-central1
GCP_ZONE=us-central1-a
DOMAIN_NAME=e2b.quexio.com
PROVIDER=gcp
PREFIX=e2b-
TERRAFORM_ENVIRONMENT=dev
POSTGRES_CONNECTION_STRING='postgresql://e2b:<redacted>@<cloud-sql-public-ip>:5432/e2b_cf?sslmode=require'

SERVER_MACHINE_TYPE=e2-standard-2
SERVER_CLUSTER_SIZE=1
SERVER_BOOT_DISK_SIZE_GB=30

API_MACHINE_TYPE=e2-standard-4
API_CLUSTER_SIZE=1

CLICKHOUSE_MACHINE_TYPE=e2-standard-4
CLICKHOUSE_CLUSTER_SIZE=1
CLICKHOUSE_STATEFUL_DISK_SIZE_GB=100
CLICKHOUSE_RESOURCES_CPU=2
CLICKHOUSE_RESOURCES_MEMORY_MB=3072

DASHBOARD_API_COUNT=1
LOKI_CLUSTER_SIZE=0
REDIS_MANAGED=false
REDIS_SHARD_COUNT=1

FILESTORE_CACHE_ENABLED=false
ANYWHERE_CACHE_ENABLED=false
```

The shorter prefix `e2b-` was important because GCP service account IDs must be between 6 and 30 characters. Longer prefixes previously caused service account name failures.

## Prerequisites

Before starting the install, gather or prepare:

- GCP project ID.
- GCP region and zone.
- Cloudflare-managed domain.
- Cloudflare API token with permission to read the zone and edit DNS records.
- Cloud SQL Postgres instance with a fresh database.
- Postgres username and password.
- GCP service account or user with permissions to create compute, storage, IAM, certificate manager, secret manager, load balancer, and networking resources.
- Required local tools: `gcloud`, `terraform`, `packer`, `make`, `jq`, `nomad`, Node.js, npm.
- Enough GCP quota in `us-central1` for the chosen machine types, disks, addresses, load balancers, and instance groups.

## Install Flow

Run from the repo root:

```sh
cd /Users/chandrashekhar29/appointy/e2b/e2b-dev-infra
```

Select the environment:

```sh
make set-env ENV=dev
```

Initialize Terraform and providers:

```sh
make init
```

Build and upload E2B images/artifacts:

```sh
make build-and-upload
```

If the machine restarts or the command is interrupted before completion, rerun the same command. It is safe because the build/upload flow is intended to converge.

Copy required public builds:

```sh
make copy-public-builds
```

Create infrastructure without Nomad jobs first:

```sh
make plan-without-jobs
make apply
```

Wait for the managed certificate to become active:

```sh
gcloud certificate-manager certificates describe e2b-root-cert \
  --project=codefac \
  --location=global
```

Expected certificate domains:

```text
e2b.quexio.com
*.e2b.quexio.com
```

Expected state:

```text
ACTIVE
```

Configure the local Nomad CLI:

```sh
export NOMAD_ADDR=https://nomad.e2b.quexio.com
export NOMAD_REGION=us-central1
export NOMAD_TOKEN="$(gcloud secrets versions access latest \
  --secret=e2b-nomad-secret-id \
  --project=codefac)"
```

Check that the Nomad server and node pools are available:

```sh
nomad server members
nomad node pool list
nomad node status
```

Expected node pools:

```text
all
api
build
clickhouse
default
```

Then deploy the Nomad jobs:

```sh
make plan
make apply
```

Verify jobs:

```sh
nomad job status
```

Expected important jobs:

```text
api                          running
clickhouse                   running
client-proxy                 running
dashboard-api                running
docker-reverse-proxy         running
ingress                      running
redis                        running
template-manager             running
orchestrator-dev             running
```

`clickhouse-migrator` is a batch job, so it can show as `dead` after it completes successfully.

## Database Migration Flow

After infrastructure and jobs are running:

```sh
make migrate
```

Then seed and prepare the base template:

```sh
make prep-cluster
```

When prompted for the base template team API key, use the generated team API key from the seed step. It starts with:

```text
e2b_
```

Do not use the cloud E2B API key for the self-hosted base template.

## Migration Patches We Applied

These patches were needed because the new database was fresh, but some Postgres roles are instance-global and had survived from the previous installation attempt.

### 1. `authenticated` Role Already Existed

File:

```text
packages/db/migrations/20000101000000_auth.sql
```

Problem:

```text
ERROR: role "authenticated" already exists
```

Reason:

Postgres roles are global to the Cloud SQL instance, not scoped to a single database. Creating a new database does not remove roles created by an earlier database.

Patch:

```sql
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
        CREATE ROLE authenticated;
    END IF;
END
$$;
```

This replaced the direct:

```sql
CREATE ROLE authenticated;
```

### 2. `trigger_user` Role Already Existed

File:

```text
packages/db/migrations/20231220094836_create_triggers_and_policies.sql
```

Problem:

The migration can fail if `trigger_user` already exists from a previous install.

Reason:

Same as above. `trigger_user` is a Postgres role/user and is global to the Cloud SQL instance.

Patch:

```sql
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'trigger_user') THEN
        CREATE USER trigger_user;
    END IF;
END
$$;
```

This replaced the direct:

```sql
CREATE USER trigger_user;
```

### 3. `env_aliases.is_name` Rename Was Not Idempotent

File:

```text
packages/db/migrations/20240315165236_create_env_builds.sql
```

Problem:

```text
ERROR: column "is_name" does not exist
```

Reason:

The schema already had `is_renamable`, so the old column `is_name` was no longer present. The migration tried to rename a column that had already effectively been renamed.

Patch:

```sql
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'env_aliases'
          AND column_name = 'is_name'
    ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'env_aliases'
          AND column_name = 'is_renamable'
    ) THEN
        ALTER TABLE "public"."env_aliases" RENAME COLUMN "is_name" TO "is_renamable";
    END IF;
END
$$;
```

This replaced the direct:

```sql
ALTER TABLE IF EXISTS "public"."env_aliases" RENAME COLUMN "is_name" TO "is_renamable";
```

## Migration Table Repair

During retries, the migration state table had duplicate older migration rows after newer 2026 migrations. Goose uses the latest row by migration table ordering to determine the current version, so duplicate older rows at the end can confuse it.

Checks used:

```sql
SELECT *
FROM _migrations
ORDER BY id DESC
LIMIT 10;
```

```sql
SELECT COUNT(*)
FROM _migrations
WHERE is_applied = true;
```

```sql
SELECT to_regclass('public.env_builds');
```

```sql
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'env_aliases'
  AND column_name IN ('is_name', 'is_renamable');
```

Rows deleted after confirming they were duplicate older versions:

```sql
DELETE FROM _migrations
WHERE id = 115
  AND version_id = 20240305221944;

DELETE FROM _migrations
WHERE id IN (113, 114);
```

These IDs were specific to this database state. Do not blindly reuse them in another database. Always inspect `_migrations` first and only delete duplicate older rows that appear after the latest migration version.

Expected final top migration row:

```text
20260702120000
```

## ClickHouse Node Pool Note

In the earlier failed installation, ClickHouse jobs failed with:

```text
job "clickhouse" is in nonexistent node pool "clickhouse"
```

In the clean installation after pulling the latest upstream changes and using the shorter prefix, the `clickhouse` node pool was created automatically.

Verification:

```sh
nomad node pool list
```

Expected:

```text
clickhouse
```

If this ever happens again, the immediate diagnostic is:

```sh
nomad node pool list
nomad node status
nomad job status clickhouse
```

The fallback manual repair is:

```sh
cat > /tmp/clickhouse-node-pool.hcl <<'EOF'
node_pool "clickhouse" {
  description = "Nodes for ClickHouse."
}
EOF

nomad node pool apply /tmp/clickhouse-node-pool.hcl
```

But this should not be necessary in the clean installation.

## Sandbox Smoke Test

The base template created by `make prep-cluster` is `base`. If code uses `code-interpreter-v1`, the API returns:

```text
template 'code-interpreter-v1' not found
```

Use `base` unless you have explicitly built/imported another template.

From the explore project:

```sh
cd /Users/chandrashekhar29/appointy/e2b/explore
```

Set the self-hosted endpoint and team API key:

```sh
export E2B_DOMAIN=e2b.quexio.com
export E2B_API_KEY='<team-api-key-starting-with-e2b_>'
```

Run:

```sh
npx tsx ./index.ts
```

Expected result:

```text
hello world
```

and a sandbox file listing.

## Useful Debug Commands

Nomad CLI setup:

```sh
export NOMAD_ADDR=https://nomad.e2b.quexio.com
export NOMAD_REGION=us-central1
export NOMAD_TOKEN="$(gcloud secrets versions access latest \
  --secret=e2b-nomad-secret-id \
  --project=codefac)"
```

Nomad health:

```sh
nomad server members
nomad operator raft list-peers
nomad node pool list
nomad node status
nomad job status
```

Specific jobs:

```sh
nomad job status api
nomad job status dashboard-api
nomad job status template-manager
nomad job status clickhouse
nomad job status orchestrator-dev
```

Trigger a new evaluation if a job was pending and capacity has since appeared:

```sh
nomad job eval api
nomad job eval template-manager
nomad job eval clickhouse
```

List E2B VMs:

```sh
gcloud compute instances list \
  --project=codefac \
  --filter='name~^e2b' \
  --format='table(name,zone,status,creationTimestamp,networkInterfaces[0].networkIP)'
```

List load balancer backend services:

```sh
gcloud compute backend-services list \
  --project=codefac \
  --global \
  --filter='name~^e2b'
```

Check backend health. Use the actual backend service name from the previous command:

```sh
gcloud compute backend-services get-health <backend-service-name> \
  --project=codefac \
  --global
```

Check certificate:

```sh
gcloud certificate-manager certificates describe e2b-root-cert \
  --project=codefac \
  --location=global
```

SSH to a VM and check local Nomad agent health:

```sh
gcloud compute ssh <vm-name> \
  --project=codefac \
  --zone=<zone> \
  --command='curl -sS http://127.0.0.1:4646/v1/agent/health || true'
```

Restart Nomad on a VM only as a temporary operational fix:

```sh
gcloud compute ssh <vm-name> \
  --project=codefac \
  --zone=<zone> \
  --command='sudo supervisorctl restart nomad; sleep 8; curl -sS http://127.0.0.1:4646/v1/agent/health || true'
```

If repeated restarts are needed, investigate the root cause instead of relying on restart loops.

## Notes From The Previous Failed Install

The earlier install had several useful lessons:

- Long prefixes can break GCP service account name limits.
- A domain change is not just cosmetic. It changes certificates, DNS records, load balancer routing, API endpoint, sandbox routing, and environment variables used by local clients.
- `make plan-without-jobs` is used first because Nomad jobs require the cluster, load balancer, certificates, buckets, and artifacts to exist.
- `make plan` can fail with Nomad `503` if the Nomad backend is temporarily unhealthy. Wait for backend health and retry.
- Server recreation or state loss can leave Nomad with no jobs and no nodes. In that case, confirm whether the server VM was recreated and whether Nomad data survived.
- Manual node pool creation should not be part of the normal path. In the successful reinstall, `clickhouse` was created by the installation flow.

## Security Notes

- Do not commit `.env.dev` with real passwords or tokens.
- Do not commit generated API keys from `make prep-cluster`.
- Store the generated team API key securely.
- Rotate credentials if they were pasted into logs, terminals, or chat.
- Treat Nomad management tokens as sensitive.

