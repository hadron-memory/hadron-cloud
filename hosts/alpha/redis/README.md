# Redis on alpha

Installed from packages.redis.io (bare metal, `redis-server.service`).
Config: `/etc/redis/redis.conf`. Two lines are managed by us:

```
bind 127.0.0.1 172.17.0.1 172.18.0.1 -::1
protected-mode no
```

- `172.17.0.1` = default bridge gateway, `172.18.0.1` = `komodo_default`
  gateway — this is how containers reach Redis via `host.docker.internal`.
  The `-::1` keeps startup from failing if IPv6 localhost is unavailable.
- `protected-mode no` is required because there's no `requirepass`;
  exposure is limited to localhost + Docker bridges (nothing external —
  Hetzner firewall doesn't open 6379).
- No auth yet. To add `requirepass`, first put the password into each
  consuming app's Doppler config, then update redis.conf and restart.

Plus the boot-ordering drop-in: [wait-for-docker.conf](wait-for-docker.conf).

Persistence: RDB snapshots (default `save` rules). Enable AOF
(`appendonly yes`) if Redis ever holds data that can't be regenerated.
