# kcp-argocd-test

## Start the kcp + argocd dev env

Create a local kcp environment:

```bash
make start
```

Deploy argocd into the physical cluster. This will install argocd directly into the physical kind cluster and deploy an application that points to the `test` kcp workspace:

```bash
make argocd-setup
```

Serve argocd-server in localhost:

```bash
make argocd-port-forward
```

Show the password for the argocd admin user:

```bash
make argocd-password
```

## Tear down the environment

Stop kcp control plane and delete the kind cluster:

```bash
make stop
```

Remove all data:

```bash
make clean
```
