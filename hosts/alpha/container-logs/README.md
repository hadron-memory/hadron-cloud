# Container log limits on alpha

Docker's default `json-file` log driver has no size limit, and alpha has no `/etc/docker/daemon.json`. Before this change, every container's log could grow until the disk filled. An 18 GB `hadrontool-slack` log was one cause of the 2026-09-29 disk-full outage (#13, `hrn:node:hadronmemory.com:dev:ops:alpha:docker-log-rotation-gap`).

## The limit

Each Komodo deployment carries these Docker run arguments in its `extra_args`, after any arguments it already had:

```
--log-opt max-size=50m --log-opt max-file=5
```

That is at most 250 MB of logs per container (five 50 MB files, rotated by Docker). `hadron-server` has carried this since 2026-10-28 (the hadron-internal#4 deploy). The others got it on 2026-11-07.

Why per deployment and not a `daemon.json` default:
- A daemon default needs a dockerd restart, which stops every container at once unless live-restore is on.
- It applies only to containers created afterwards.
- Komodo recreates a container on each deploy with whatever `extra_args` holds, so per-deployment arguments survive auto-deploys. `hadron-server` kept its cap through every deploy between 2026-10-28 and 2026-11-07.

**New deployments:** add the two `--log-opt` pairs to `extra_args` when you create the deployment.

## State on 2026-11-07

Capped and recreated once, on the same image (the configured build version is the running one):
`hadron-server` (earlier), `hadron-portal`, `hadron-cms`, `hadrontool-gmail`, `hadrontool-google-cal`, `hadrontool-google-drive`, `hadrontool-home-assistant`, `hadrontool-mcp`, `hadrontool-pdf`, `hadrontool-resend`, `hadrontool-scan`, `hadrontool-telegram`, `hadrontool-twilio`, `hadrontool-webfetch`.

Capped in config only, not deployed: `hadrontool-slack`. It has been stopped since 2026-09-29, and a deploy would start it. It takes the cap whenever it is next deployed.

Not yet capped. Each needs its own decision:

| Container | Why it was left |
| --- | --- |
| `hadrontool-ms-exchange` | Runs 0.0.1, but its configured build resolves to 0.0.3. A deploy would upgrade the image. |
| `clamav` | Uses the moving tag `clamav/clamav:1.4`, and the registry digest differs from the running image, so a deploy would pull a new image. |
| `kcu`, `mrserver`, `tapco` | Market Railz apps, not Hadron's. `mrserver`'s log was 487 MB on 2026-11-07. |
| `komodo-core-1`, `komodo-periphery-1`, `komodo-traefik-1` | Komodo's own compose stack, not a Komodo deployment. Recreating Traefik interrupts every public route. |

## Check

```bash
ssh root@alpha 'for c in $(docker ps --format "{{.Names}}"); do echo "$c $(docker inspect -f "{{json .HostConfig.LogConfig.Config}}" $c)"; done'
```

`{}` means that container's log has no limit.
