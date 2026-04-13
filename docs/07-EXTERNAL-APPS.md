# 07 — Apps externes (GHCR + GitHub Actions)

## Principe

```
Repo externe         GitHub Actions          zero-trust
(code)               (build)                 (déploiement)
git tag v1.0.0  →    build multi-arch   →    group_vars/all.yml
                     push GHCR               version: "1.0.0"
                                             docker compose pull
```

Le code source ne touche JAMAIS les serveurs. La config (secrets, ports) est gérée par zero-trust via `.env`.

## Repos

| Repo | Images | Particularité |
|------|--------|---------------|
| `ldesfontaine/termfolio` | `termfolio` | Image unique |
| `ldesfontaine/bientot` | `bientot-agent` + `bientot-server` | Multi-target |
| `ldesfontaine/veille-secu` | `veille-secu` | Image unique |

## Workflow image unique

`.github/workflows/docker.yml` sur termfolio et veille-secu :

```yaml
name: Build & Push
on: { push: { tags: ['v*'] } }
env: { REGISTRY: ghcr.io, IMAGE_NAME: "${{ github.repository }}" }
jobs:
  build:
    runs-on: ubuntu-latest
    permissions: { contents: read, packages: write }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-qemu-action@v3
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }
      - id: meta
        uses: docker/metadata-action@v5
        with: { images: "${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}", tags: "type=semver,pattern={{version}}\ntype=sha,prefix=" }
      - uses: docker/build-push-action@v6
        with: { context: ., platforms: "linux/amd64,linux/arm64", push: true, tags: "${{ steps.meta.outputs.tags }}", cache-from: "type=gha", cache-to: "type=gha,mode=max" }
```

## Workflow multi-target (Bientôt)

```yaml
    strategy:
      matrix:
        include:
          - { target: agent, image: bientot-agent }
          - { target: server, image: bientot-server }
    steps:
      # ... setup identique ...
      - uses: docker/build-push-action@v6
        with:
          context: .
          target: ${{ matrix.target }}
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ghcr.io/ldesfontaine/${{ matrix.image }}:${{ steps.version.outputs.version }}
```

## Publier

```bash
cd termfolio && git tag v1.3.0 && git push origin --tags    # → build → GHCR
ansible-vault edit group_vars/all.yml                        # version: "1.3.0"
ansible-playbook playbooks/services.yml --tags services --limit lan --ask-vault-pass
```

## Packages publics

GitHub → Packages → package → Settings → Change visibility → **Public**. Sinon `docker login ghcr.io` avec PAT sur chaque serveur.
