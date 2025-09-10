# Home ops

![kubefetch](cluster.png "kubefetch")

> [!NOTE]
> TODO

## Hardware

2x HP prodesk 600 G5.
1x HP elitedesk 800 G1

One old desktop as nas.

## 🤝 Thanks

The template [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template)

### TODO

task for posgres restore.

`kubectl annotate -n media postgrescluster immich-database --overwrite postgres-operator.crunchydata.com/pgbackrest-restore="$(date)"`
`kubectl patch secret immich-database-pguser-immich -n media -p '{"data":{"password":""}}'`
