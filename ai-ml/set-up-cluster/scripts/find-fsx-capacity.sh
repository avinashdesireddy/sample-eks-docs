#!/usr/bin/env bash
# Probe FSx for Lustre capacity across multiple AZs and print the first subnet that succeeds.
#
# There is no AWS API to pre-check FSx physical capacity - the only way to know is to attempt
# CreateFileSystem and wait for AVAILABLE vs FAILED. FSx for Lustre also uses a single subnet, so
# there is no native multi-AZ. This script does probe-and-fallback: it tries each candidate subnet
# in turn, waits for the result, deletes the file system if it FAILED (insufficient capacity), and
# moves on. On the first success it prints the winning subnet + file system id and stops.
#
# The winning file system is EFA-enabled and matches what fsx-lustre.tf would create, so you can
# adopt it into Terraform (terraform import) instead of letting Terraform re-create it - avoiding a
# second capacity gamble. See the README section "Find capacity across AZs".
#
# Usage:
#   ./find-fsx-capacity.sh \
#       --region ap-south-1 \
#       --security-group-id sg-xxxx \
#       --subnets subnet-aaa,subnet-bbb,subnet-ccc \
#       [--storage-capacity 38400] [--throughput 125] [--keep]
#
#   # or let it discover discovery-tagged private subnets (one per AZ) for a cluster:
#   ./find-fsx-capacity.sh --region ap-south-1 --cluster ai-eks-docs --security-group-id sg-xxxx
#
# Flags:
#   --keep   leave the winning file system in place (default). Without a success it exits non-zero.
set -euo pipefail

REGION="" SG="" SUBNETS_CSV="" CLUSTER="" CAPACITY=38400 THROUGHPUT=125
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)            REGION="$2"; shift 2 ;;
    --security-group-id) SG="$2"; shift 2 ;;
    --subnets)           SUBNETS_CSV="$2"; shift 2 ;;
    --cluster)           CLUSTER="$2"; shift 2 ;;
    --storage-capacity)  CAPACITY="$2"; shift 2 ;;
    --throughput)        THROUGHPUT="$2"; shift 2 ;;
    --keep)              shift ;;   # default behavior; accepted for clarity
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$REGION" ]] || { echo "ERROR: --region is required" >&2; exit 2; }
[[ -n "$SG" ]]     || { echo "ERROR: --security-group-id is required" >&2; exit 2; }

# Build the candidate subnet list.
if [[ -n "$SUBNETS_CSV" ]]; then
  IFS=',' read -r -a SUBNETS <<< "$SUBNETS_CSV"
elif [[ -n "$CLUSTER" ]]; then
  # One private (discovery-tagged) subnet per AZ. Read into an array without mapfile so this
  # works on the bash 3.2 that ships with macOS.
  echo "Discovering discovery-tagged private subnets for cluster '$CLUSTER'..." >&2
  SUBNETS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && SUBNETS+=("$line")
  done < <(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER" \
    --query 'Subnets[].[AvailabilityZone,SubnetId]' --output text \
    | sort -u -k1,1 | awk '{print $2}')
else
  echo "ERROR: provide --subnets or --cluster" >&2; exit 2
fi

[[ ${#SUBNETS[@]} -gt 0 ]] || { echo "ERROR: no candidate subnets" >&2; exit 2; }

echo "Probing FSx PERSISTENT_2 (EFA, ${CAPACITY} GiB @ ${THROUGHPUT} MB/s/TiB) across ${#SUBNETS[@]} subnet(s):" >&2
for s in "${SUBNETS[@]}"; do
  az=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$s" \
       --query 'Subnets[0].AvailabilityZone' --output text)
  echo "  - $s ($az)" >&2
done

for SUBNET in "${SUBNETS[@]}"; do
  AZ=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$SUBNET" \
       --query 'Subnets[0].AvailabilityZone' --output text)
  echo >&2
  echo "=== Trying $SUBNET ($AZ) ===" >&2

  FS_ID=$(aws fsx create-file-system --region "$REGION" \
    --file-system-type LUSTRE \
    --storage-type SSD \
    --storage-capacity "$CAPACITY" \
    --subnet-ids "$SUBNET" \
    --security-group-ids "$SG" \
    --lustre-configuration "{
      \"DeploymentType\": \"PERSISTENT_2\",
      \"PerUnitStorageThroughput\": $THROUGHPUT,
      \"EfaEnabled\": true,
      \"DataCompressionType\": \"NONE\",
      \"MetadataConfiguration\": {\"Mode\": \"AUTOMATIC\"}
    }" \
    --query 'FileSystem.FileSystemId' --output text) || {
      echo "  create call rejected in $AZ (see error above); moving on." >&2
      continue
    }

  echo "  created $FS_ID; waiting for AVAILABLE/FAILED (usually 5-10 min)..." >&2
  while true; do
    LIFE=$(aws fsx describe-file-systems --region "$REGION" --file-system-ids "$FS_ID" \
           --query 'FileSystems[0].Lifecycle' --output text 2>/dev/null || echo "MISSING")
    case "$LIFE" in
      AVAILABLE)
        echo "  SUCCESS in $AZ." >&2
        DNS=$(aws fsx describe-file-systems --region "$REGION" --file-system-ids "$FS_ID" \
              --query 'FileSystems[0].DNSName' --output text)
        MOUNT=$(aws fsx describe-file-systems --region "$REGION" --file-system-ids "$FS_ID" \
                --query 'FileSystems[0].LustreConfiguration.MountName' --output text)
        # Machine-readable result on stdout (everything else went to stderr).
        echo "FSX_SUBNET_ID=$SUBNET"
        echo "FSX_AZ=$AZ"
        echo "FSX_FILE_SYSTEM_ID=$FS_ID"
        echo "FSX_DNS_NAME=$DNS"
        echo "FSX_MOUNT_NAME=$MOUNT"
        exit 0
        ;;
      FAILED)
        echo "  FAILED in $AZ (insufficient capacity). Deleting $FS_ID and trying next AZ." >&2
        aws fsx delete-file-system --region "$REGION" --file-system-id "$FS_ID" >/dev/null || true
        break
        ;;
      MISSING)
        echo "  $FS_ID vanished; trying next AZ." >&2
        break
        ;;
      *)
        sleep 20
        ;;
    esac
  done
done

echo >&2
echo "No AZ had capacity for the requested configuration. Try again later, or lower --throughput." >&2
exit 1
