# hadron-server logs go to journald (alpha)

**Why.** With Docker's `json-file` driver a container's log is deleted with the container, and Komodo removes the old container on every deploy. On 2026-11-10 the 11:22Z deploy stop (0.0.1874 → 0.0.1875) exited 1 and its logs were already gone (hadron-cloud#15, hadron-server#3845). With `journald` the logs live in the host journal and outlive the container.

**What changed (2026-11-10, Otto, register row "hadron-cloud#15 / hadron-server#3845: keep hadron-server's container logs").** The `hadron-server` Komodo Deployment's `extra_args`, and nothing else:

```
before: --add-host=host.docker.internal:host-gateway --memory=6g --log-opt max-size=50m --log-opt max-file=5
after:  --add-host=host.docker.internal:host-gateway --memory=6g --log-driver journald --log-opt tag=hadron-server
```

The json-file caps had to be **replaced**, not kept: `max-size`/`max-file` are json-file options and Docker refuses them under `journald`, so the next deploy would have failed to start the container.

Config only. It takes effect when the next normal deploy recreates the container; no restart was triggered for it. No `daemon.json`, no dockerd restart, no other container. The old value is saved on alpha in `/root/komodo/hadron-server-extra-args-before-journald-20261110.json`.

**Disk bound.** journald, not Docker, bounds it: alpha's journal is persistent (`/var/log/journal`) with the default cap (4 GB, about six months of host logs on 2026-11-10). hadron-server logs a few KB per minute.

**Rehearsed** first on the `otto-bg` Incus stack (Komodo 2.3.4, alpha runs 2.3.3; Docker 26 vs alpha's 29, both list the journald plugin): a Deployment with these exact args deployed, redeployed and was destroyed. Both containers' log lines stayed in the journal after removal, while `docker logs` on the removed container failed.

## Reading the logs

```bash
ssh root@alpha
journalctl -t hadron-server --since -1h            # all hadron-server containers
journalctl CONTAINER_NAME=hadron-server -o short-iso
journalctl -t hadron-server CONTAINER_ID=<12-char id>   # one container, also after removal
docker logs hadron-server                          # still works for the running container
```

## Rollback

Set `extra_args` back to the "before" line above in Komodo (UI, or `UpdateDeployment` with only `extra_args`). It takes effect at the next deploy, like the change itself.

## Verify on the first deploy after the change

`docker inspect -f '{{json .HostConfig.LogConfig}}' hadron-server` shows `{"Type":"journald","Config":{"tag":"hadron-server"}}`; `journalctl -t hadron-server` has the new container's boot lines; after the deploy, the outgoing container's lines are still readable by its `CONTAINER_ID`.
