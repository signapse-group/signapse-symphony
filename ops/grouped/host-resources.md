# Symphony host resource limits

On the grouped Symphony host `dgminhtam`, run the installer from a reviewed
source snapshot of the merged release. The versioned policy is
[`scripts/configure_user_slice.py`](../../scripts/configure_user_slice.py).
Keep that script with `scripts/deploy_symphony.py` and
`scripts/host_cleanup.py` from the same revision for the existing atomic
write and locking helpers. The binary deployment does not install host limits.

The installer expects the system manager's active cgroup v2 `user.slice`,
the existing 8 GiB hard cap, and the existing persistent control drop-ins
for `/dev/sda`. It sets the soft cap to 7.5 GiB and the disk read and write
caps to 200 MB/s and 100 MB/s. These limits are shared by all user sessions.
No restart is needed for this change.

From the staged source root, set `release_sha` to the verified full main SHA
and run:

```sh
sudo -n python3 -B scripts/configure_user_slice.py apply "$release_sha"
python3 -B scripts/configure_user_slice.py verify
```

Keep the JSON output with the rollout receipt. It includes effective values
and the persisted drop-ins. The root-only pre-change backup is
`/var/lib/symphony-host-resources/$release_sha.json`. Apply is idempotent
and will not overwrite an existing pre-change backup. A failed apply
attempts to restore the four values from that backup.

If a rollback is needed, use the same source snapshot and release SHA:

```sh
sudo -n python3 -B scripts/configure_user_slice.py rollback "$release_sha"
```

Confirm the rollback receipt and the host state:

```sh
systemctl show user.slice -p MemoryHigh -p MemoryMax -p IOReadBandwidthMax -p IOWriteBandwidthMax
cat /sys/fs/cgroup/user.slice/memory.high /sys/fs/cgroup/user.slice/memory.max /sys/fs/cgroup/user.slice/io.max
```

Rollback changes only the managed limits. Do not use `systemctl revert
user.slice`, which would also remove unrelated local settings.
