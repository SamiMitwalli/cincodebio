# CincoDeBio All-in-One Docker Image

Run the complete CincoDeBio platform inside a **single Docker container** using [k3s](https://k3s.io/) (lightweight Kubernetes). The only dependency is **Docker**.

## Quick Start

```bash
# Build (from the cincodebio/ directory)
docker build -f docker/Dockerfile -t cincodebio-aio .

# Run
docker run -d --privileged --cgroupns=host --name cincodebio \
  -p 80:80 \
  -e DOCKER_HUB_USERNAME=<your-dockerhub-user> \
  -e DOCKER_HUB_PASSWORD=<your-dockerhub-password> \
  cincodebio-aio

# Watch startup logs (~5 minutes on first run)
docker logs -f cincodebio

# Once you see "CincoDeBio is ready!" open:
#   http://localhost/app/
```

## What's Inside

The container packages:

| Component | Purpose |
|-----------|---------|
| **k3s** (Kubernetes v1.28) | Container orchestration |
| **nginx-ingress** | Routes HTTP traffic to services |
| **cert-manager** v1.17.2 | TLS certificates (self-signed for local) |
| **Container registry** | In-cluster image registry for kaniko builds |
| **CincoDeBio Helm chart** | All 11 application services + MongoDB + MinIO + RabbitMQ |

## Access Points

All services are accessible through a single port (80) via ingress routing:

| Service | URL |
|---------|-----|
| Frontend | `http://localhost/app/` |
| Minio Console | `http://localhost/minio-console/` |
| Execution API | `http://localhost/execution-api/ext/...` |
| Service API | `http://localhost/services-api/ext/...` |
| SIB Manager | `http://localhost/sib-manager/ext/...` |
| Data Manager | `http://localhost/data-manager/ext/...` |
| Jobs API | `http://localhost/jobs-api/ext/...` |

## Management

```bash
# View pods
docker exec cincodebio kubectl get pods

# View logs for a service
docker exec cincodebio kubectl logs -l app=sib-manager

# Restart a service
docker exec cincodebio kubectl rollout restart deployment/sib-manager

# Stop
docker stop cincodebio && docker rm cincodebio
```

## Persist Data Across Restarts

Mount a volume for k3s state:

```bash
docker run -d --privileged --cgroupns=host --name cincodebio \
  -p 80:80 \
  -e DOCKER_HUB_USERNAME=<user> \
  -e DOCKER_HUB_PASSWORD=<pass> \
  -v cincodebio-data:/var/lib/rancher/k3s \
  cincodebio-aio
```

> **Note:** The first run always performs a fresh install. On subsequent runs with the same volume, k3s restores previous state.

## Requirements

- **Docker** (Docker Desktop on macOS/Windows, Docker Engine on Linux)
- **4 GB+ RAM** allocated to Docker
- **~10 GB disk** for images and data
- **Internet access** on first run (pulls container images)

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Container exits immediately | Check logs: `docker logs cincodebio` — likely missing `-e` credentials |
| Services not reachable on port 80 | Ensure no other process uses port 80, or map to another port: `-p 8080:80` |
| Image pull errors inside container | Check internet connectivity; retry `docker stop/rm/run` |
| Slow first start (>10 min) | Normal on first run — images are pulled from DockerHub |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Docker Container (--privileged)                    │
│                                                     │
│  k3s (Kubernetes v1.28)                             │
│  ├── nginx-ingress :80 ──→ hostPort ──→ -p 80:80   │
│  ├── cert-manager                                   │
│  ├── container registry :5000 (hostPort)            │
│  │                                                  │
│  └── default namespace                              │
│      ├── frontend                                   │
│      ├── sib-manager → kaniko → service-api         │
│      ├── execution-api                              │
│      ├── jobs-api                                   │
│      ├── data-manager                               │
│      ├── code-generator                             │
│      ├── ontology-manager                           │
│      ├── execution-environment                      │
│      ├── mongodb                                    │
│      ├── minio                                      │
│      └── rabbitmq                                   │
└─────────────────────────────────────────────────────┘
         ▲
         │ -p 80:80
         ▼
    http://localhost/app/
```

## Alternatives

If you need more flexibility than the all-in-one container:

| Approach | Dependencies | Pros | Cons |
|----------|-------------|------|------|
| **This image** | Docker only | Simplest setup, single command | `--privileged --cgroupns=host`, no hot-reload |
| **install.sh + minikube** | Docker, minikube, helm, kubectl | Full control, live code editing | 4 tool installs |
| **k3d** | Docker, k3d | Lightweight clusters, multi-node support | 1 extra binary |
| **kind** | Docker, kind | Production-like kubeadm clusters | 1 extra binary, heavier |
| **Docker Compose** | Docker, docker-compose | No Kubernetes overhead | Requires rewriting all manifests |
