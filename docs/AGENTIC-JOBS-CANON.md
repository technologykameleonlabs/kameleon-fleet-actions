# Agentic Jobs canon

Documentación canónica del patrón de ejecución del piloto agentic tras la migración del 2026-06-09 desde pods persistentes a Jobs efímeros.

## Por qué

El piloto original usaba 6 pods con `sleep infinity` (orchestrator + 2 workers + reviewer + integrator + fixer). Limitaciones que motivaron la migración:

| Problema | Síntoma observado |
|---|---|
| Cross-talk entre runs paralelos | 2 Codex en el mismo pod compartían `/home/agent/work/`. Branches mezcladas, ramas residuales. |
| Capacity model rígido | 2 workers fijos. Si llegaban 5 issues a la vez, 3 se encolaban. |
| State acumulado | Caches git, branches residuales, procesos zombi. |
| Race condition OAuth | Múltiples pods refrescaban el mismo refresh_token con OpenAI invalidando el viejo → 401 cascada. |
| Resiliencia limitada | Si el pod orchestrator caía, todo el ciclo paraba. |

Patrón canon: **un Job efímero por unidad de trabajo** (1 issue → 1 worker Job, 1 PR → 1 reviewer Job, 1 KAF Historia → 1 orchestrator Job).

## Arquitectura

```
┌─────────────────────────────────────────────────┐
│ agentic-auth namespace                          │
│                                                 │
│  Pod oauth-broker (1 replica)                   │
│   - container keepalive: codex login status c/m │
│   - container server: HTTP :8080 /auth.json     │
│   - PVC oauth-broker-state (RWO 1Gi)            │
│                                                 │
│  Service oauth-broker (ClusterIP)               │
│  NetworkPolicy: ingress solo namespaces         │
│   con label canon.kameleonlabs.ai/agentic-jobs  │
└─────────────────────────────────────────────────┘
                   │
                   │ GET /auth.json (Bearer SA token)
                   ▼
┌─────────────────────────────────────────────────┐
│ <producto>-lab namespace                        │
│  (ej. kameleonapp-lab, padelpeak-lab, ...)      │
│                                                 │
│  Jobs efímeros (TTL 5 min):                     │
│   - agentic-reviewer-<pr>-<run>                 │
│   - agentic-worker-issue-<n>-<run>              │
│   - agentic-orchestrator-<kaf>-<run>            │
│   - agentic-fixer-pr-<n>-<attempt>-<run>        │
│                                                 │
│  Cada Job:                                      │
│   1. initContainer fetch-auth: descarga         │
│      auth.json del broker.                       │
│   2. initContainer clone-repo (excepto reviewer)│
│      shallow clone fresh del repo.              │
│   3. container agent: ejecuta Codex.            │
│   4. STDOUT con markers JSON resultado          │
│      (--BEGIN-<ROLE>-OUTPUT--).                 │
└─────────────────────────────────────────────────┘
```

## Templates de Job

Repositorio: `kameleonapp-lab/.github/k8s/agentic-jobs/`

| Template | Rol | Inputs (envsubst) | Output STDOUT |
|---|---|---|---|
| `reviewer-job-template.yaml` | Adversarial review | DIFF_B64, PROMPT_B64 | `{"findings":[...]}` entre `--BEGIN-REVIEW-OUTPUT--` |
| `worker-job-template.yaml` | Procesa issue → sub-PR | ISSUE_NUMBER, BRANCH, APP_TOKEN_B64, PROMPT_B64 | `{"push":"pushed","commits_ahead":N,"head_sha":"..."}` |
| `orchestrator-job-template.yaml` | Procesa Historia → Change SDD | KAF_KEY, KG_BASE_URL, PROMPT_B64, KAF_API_KEY_B64 | `{"codex_rc":N,"kaf_key":"...","changed_dirs_sample":"..."}` |
| `fixer-job-template.yaml` | Auto-fix integration-check fail | PR_NUMBER, BRANCH, ATTEMPT, FAILURE_CONTEXT_B64, PROMPT_B64 | `{"push":"pushed","before_sha":"...","after_sha":"..."}` |

## Workflows GHA canon

Repositorio: `kameleonapp-lab/.github/workflows/`

| Workflow | Trigger | Job template usado |
|---|---|---|
| `adversarial-review-jobs.yml` | `pull_request: opened/synchronize/reopened` + `workflow_dispatch` | reviewer |
| `agents-worker.yml` | `issues: labeled (agent-worker:pending)` + `workflow_dispatch` | worker |
| `orchestrator-dispatch.yml` | `workflow_dispatch` (kaf_key) + k8s CronJob in cluster | orchestrator |
| `agents-error-fix.yml` | `workflow_run: integration-check completed (failure on agent/* branch)` | fixer |

Patrón común en cada workflow:

```yaml
- name: Install envsubst
  run: |
    if ! command -v envsubst >/dev/null 2>&1; then
      sudo apt-get update -qq
      sudo apt-get install -y -qq gettext-base || sudo apt-get install -y -qq gettext
    fi

- name: Mint Fleet App installation token
  uses: actions/create-github-app-token@v1
  with:
    app-id: ${{ secrets.KL_FLEET_APP_ID }}
    private-key: ${{ secrets.KL_FLEET_APP_PRIVATE_KEY }}

- name: Render + create Job
  run: |
    export VAR1 VAR2 VAR3
    envsubst '${VAR1} ${VAR2} ${VAR3}' \
      < .github/k8s/agentic-jobs/<role>-job-template.yaml \
      > /tmp/job.yaml
    kubectl create -f /tmp/job.yaml

- name: Wait for Job
  run: |
    set +e
    kubectl wait --for=condition=complete --timeout=28m "job/$JOB_NAME" -n <ns>
    R=$?
    if [ $R -ne 0 ]; then
      kubectl wait --for=condition=failed --timeout=30s "job/$JOB_NAME" -n <ns>
    fi

- name: Extract output via kubectl logs
  run: |
    kubectl logs "job/$JOB_NAME" -c agent -n <ns> > /tmp/job.log
    sed -n '/^--BEGIN-X-OUTPUT--$/,/^--END-X-OUTPUT--$/{//!p}' /tmp/job.log > /tmp/output.json
```

## OAuth broker

Repositorio: `kameleon-fleet-bootstrap/oauth-broker/`

Componentes manifest:
- `01-namespace.yaml` — namespace `agentic-auth`.
- `02-pvc.yaml` — PVC `oauth-broker-state` RWO 1Gi.
- `03-rbac.yaml` — ServiceAccount + ClusterRoleBinding TokenReview.
- `04-configmap-server.yaml` — código Python del HTTP server (sin deps externas).
- `05-deployment.yaml` — Pod con 2 containers (keepalive + server).
- `06-service.yaml` — ClusterIP :8080.
- `07-networkpolicy.yaml` — ingress por label.

Secret bootstrap:
- `openai-bootstrap-auth` con `auth.json` capturado tras device flow inicial. Solo se usa la primera vez (init container copia al PVC). Refresh continuo del PVC.

Refresh token mortis (procedimiento):

Si el refresh token muere server-side (sesión cerrada desde otro dispositivo, etc.), `/healthz` empezará a devolver 503. Procedimiento:

```bash
# 1. Device flow desde el container keepalive
kubectl exec -n agentic-auth deployment/oauth-broker -c keepalive -- \
  /home/agent/.local/bin/codex login --device-auth

# 2. Mostrar URL + código al humano, esperar autorización en navegador.

# 3. Update Secret bootstrap con el nuevo auth.json (siguiente arranque ya OK):
kubectl exec -n agentic-auth deployment/oauth-broker -c keepalive -- \
  cat /state/auth.json > /tmp/auth.json
kubectl create secret generic openai-bootstrap-auth \
  --from-file=auth.json=/tmp/auth.json \
  --dry-run=client -o yaml -n agentic-auth | kubectl apply -f -
```

## Onboarding de un producto nuevo

Para que un producto nuevo (PadelPeak, EvaleIA, etc.) use el patrón Jobs canon:

1. **Etiquetar su namespace** para que pase la NetworkPolicy del broker:
   ```bash
   kubectl label namespace <producto>-lab canon.kameleonlabs.ai/agentic-jobs=true
   ```

2. **Añadir el namespace a `ALLOWED_NAMESPACES`** del Deployment del broker (`05-deployment.yaml`, env del container server). Re-apply el manifest.

3. **Copiar `ghcr-pull-secret`** del namespace existente al nuevo:
   ```bash
   kubectl get secret ghcr-pull-secret -n kameleonapp-lab -o yaml | \
     sed 's/namespace: kameleonapp-lab/namespace: <producto>-lab/' | \
     kubectl apply -f -
   ```

4. **Replicar `.github/k8s/agentic-jobs/*` y workflows** en el repo del producto. Solo cambiar `namespace:` en los templates y `<producto>-lab` en cada `kubectl` call.

## Observabilidad

Métricas Prometheus expuestas por el broker en `/metrics`:

- `oauth_broker_serve_total{result="ok|401|403|500"}` — GET /auth.json count.
- `oauth_broker_tokenreview_total{result="ok|fail"}` — verificaciones SA token.
- `oauth_broker_token_ttl_seconds` — segundos hasta expirar del id_token vigente.

Cluster:

```bash
# Estado Jobs activos
kubectl get jobs -A -l 'canon.kameleonlabs.ai/agentic-role'

# Logs de un Job
kubectl logs job/<name> -c agent -n <ns>

# Cleanup manual (si TTL falla por alguna razón)
kubectl delete jobs -n <ns> -l 'canon.kameleonlabs.ai/agentic-role=reviewer'
```

## Limitaciones conocidas

| Limitación | Mitigación canon |
|---|---|
| Broker 1 replica → SPOF | Si el pod muere, k8s lo recrea. PVC mantiene auth.json. Downtime ~30s. Mientras esté caído, los Jobs nuevos fallan al init. |
| Cold start del Job | clone shallow ~3-5s + pull imagen orchestrator-base (~10s en primera vez por nodo). Total ~15-20s antes de Codex empiece. |
| Refresh token expira tras N días | Requiere device flow manual. Apuntado como deuda canon: idealmente integrar con OAuth backchannel de OpenAI. |
| Cero cache git entre Jobs | Cada Job clona fresh. Si el repo crece >1GB, considerar PVC shared con sparse-checkout (HA broker required). |

## Bugs canon descubiertos durante la migración 2026-06-09

Cada uno aparece como nota inline en los templates afectados.

### Bug #1 — envsubst greedy

**Síntoma**: `Codex CLI not pre-baked at ` (path vacío). El init/agent container moría sin diagnóstico antes de Codex arrancar.

**Causa**: `envsubst` por defecto sustituye TODAS las `${VAR}` del input. Las variables del bash inline del template (`${CODEX_BIN}`, `${WORKER_OUTPUT_BEGIN}`, etc.) también se sustituyen con cadena vacía si no están exportadas en el shell del render.

**Fix canon**: pasar whitelist explícita a envsubst:
```bash
envsubst '${VAR1} ${VAR2} ${VAR3}' < template.yaml > job.yaml
```

### Bug #2 — runAsUser default era 0 (root)

**Síntoma**: `Permission denied (os error 13)`. Codex CLI no podía escribir en `/home/agent/.codex/sessions/` aunque el directorio existía.

**Causa**: el container default corre como root (UID 0). El directorio `/home/agent/.codex/` viene de la imagen pre-baked y pertenece al usuario `agent` (UID 1001). Sin `runAsUser: 1001`, Codex no podía escribir en su HOME.

**Fix canon**: en el Pod template del Job:
```yaml
securityContext:
  runAsUser: 1001
  runAsGroup: 1001
  fsGroup: 1001
```

### Bug #3 — CODEX_BIN path wrong

**Síntoma**: `Codex CLI not pre-baked in image at /home/agent/.codex/packages/standalone/current/bin/codex`.

**Causa**: ese path solo existía en los pods persistentes que tenían un init container `bootstrap-codex` que copiaba la instalación a un PVC. Los Jobs efímeros no tienen ese init.

**Fix canon**: el path real de la instalación canónica de Codex en la imagen `orchestrator-base` es `/home/agent/.local/bin/codex` (segundo `RUN curl ... | sh` del Dockerfile como user agent).

### Bug #4 — refresh token race entre pods persistentes + broker

**Síntoma**: Job init OK, Codex arrancaba, después 401 / `Your session has ended`.

**Causa**: ChatGPT Pro OAuth rota el refresh token al refrescar. Mientras el broker custodiaba auth.json snapshot, los pods persistentes seguían refrescando in-place y consumiendo el token. El broker quedaba con un refresh token caducado server-side.

**Fix canon**: la migración a Jobs canon EXIGE apagar los pods persistentes ANTES de bootstrappear el broker. NO se pueden coexistir.

### Bug #5 — apt-get sin update en arc-runner

**Síntoma**: `Package 'gettext-base' has no installation candidate` en el step de install envsubst.

**Causa**: el runner fresh no tiene apt cache poblada.

**Fix canon**: siempre `apt-get update -qq` antes:
```bash
sudo apt-get update -qq
sudo apt-get install -y -qq gettext-base || sudo apt-get install -y -qq gettext
```

### Bug #6 — GitHub App no instalado en repo

**Síntoma**: `Invalid username or token. Password authentication is not supported`. El App token venía OK del workflow pero el clone fallaba.

**Causa**: el `actions/create-github-app-token@v1` genera tokens para Installations. Si el App `KL_FLEET_APP_ID` no tiene installation en el repo objetivo (o tiene Installation con `repositories: selected` que no incluye este repo), el token sirve para algunas APIs pero NO para clone.

**Fix canon**: usar el Secret bot persistente del piloto (`<producto>-lab-orchestrator-github`) con un PAT fine-grained, montado en el Job vía `envFrom: secretRef`. Eso evita la dependencia del App.

### Bug #7 — `git clone .` sobre emptyDir mount point

**Síntoma**: `Cloning into '.'...` y luego `fatal: not in a git directory` al siguiente comando. Exit code 128 en 2 segundos.

**Causa**: `git clone . URL` requiere que el directorio esté completamente vacío. Un emptyDir mount point puede tener atributos extendidos invisibles que git interpreta como "no vacío".

**Fix canon**: clone a subdirectorio:
```bash
git clone --depth 50 --branch dev URL repo
cd repo
```

### Bug #8 — `${{ github.event.comment.body }}` inline rompe bash con backticks

**Síntoma**: workflow falla con exit 127 ("command not found") en step que usa `BODY="${{ github.event.comment.body }}"`. Loop infinito si watchdog dispara el mismo workflow tras el fail.

**Causa**: GHA expande `${{ }}` inline en el script bash ANTES de que bash parse. Si el body contiene backticks (común en comments con código, IDs de Jobs, etc.), bash los evalúa como command substitution.

**Fix canon**: leer el body via `gh api` con `comment.id`. El body es DATA, no código:
```bash
COMMENT_ID="${{ github.event.comment.id }}"
BODY=$(gh api "repos/$GITHUB_REPOSITORY/issues/comments/$COMMENT_ID" --jq '.body // ""')
```

Aplicado en `auto-assignment.yml` (commit 57b8d561) y `agents-rollback.yml` (commit 759c73c7).

### Bug #9 — CHANGE_ID con `[` `]` no válido en labels k8s

**Síntoma**: `agentic-codex-${JOB_NAME_SUFFIX}` Job creation falla con `spec.template.labels: Invalid value` y `must be no more than 63 characters`.

**Causa**: CHANGE_ID tipo `[APP-KAF-31]-remove-discovery-tab` tiene caracteres no válidos en labels k8s (`[`, `]`) + nombre supera 63 chars.

**Fix canon**: sanitize CHANGE_ID a slug minúsculas-numeros-guion + truncar nombre Job:
```bash
CHANGE_SLUG=$(echo "${CHANGE_ID}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-*//; s/-*$//' | cut -c1-25)
JOB_NAME_SUFFIX="verify-${CHANGE_SLUG}-r${GITHUB_RUN_ID}"
```

Aplicado en `change-completed.yml` (commit cb281071).

### Bug #10 — GitHub Actions schedule sub-5-min no dispara

**Síntoma**: workflow con `on: schedule: '* * * * *'` o `'*/2 * * * *'` aceptado pero NO dispara via event=schedule. Todos los runs son workflow_dispatch manual.

**Causa**: GitHub Actions no garantiza schedules sub-5-min en la práctica. Repos con muchos workflows o organizaciones bajo carga pueden skip ticks por debajo de ese floor.

**Fix canon**: schedule mínimo `*/5 * * * *`. Para autonomy más agresiva, complementar con `workflow_run` triggers reactivos a otros workflows.

### Bug #11 — k8s CronJob necesita PAT con `actions:write` para dispatch

**Síntoma**: CronJob k8s con curl al endpoint `/dispatches` devuelve `403 "Resource not accessible by personal access token"`.

**Causa**: Bot PAT canon tiene `Contents+Pull-requests+Issues R+W` pero NO `Actions R+W`.

**Fix canon**: reemplazar el k8s CronJob con un **workflow GHA con `on: schedule`** que usa `GITHUB_TOKEN` automático del runner (que SÍ tiene actions:write). Elimina la dependencia del PAT custom. Aplicado en `agentic-cron-dispatcher.yml` (commit 00bc8ea3).

### Bug #12 — Auto-merge canon ciego al build TS post-merge

**Síntoma**: adversarial review PASS → auto-merge OK → build sandbox image post-merge fail por TS error → imagen `dev-latest` no actualizada → código no llega a producción silenciosamente. Detectado visualmente por usuario.

**Causa**: el step auto-merge canon solo checkeaba `gate_status==success` del reviewer, no verificaba el build.

**Fix canon**: pre-check del check-run `Build & push image` en el HEAD SHA antes de mergear. Espera hasta 8 min (poll 30s). Si conclusion≠success → NO mergea + comment al PR. Aplicado en `adversarial-review-jobs.yml` (commit d4a0c825).

### Bug #13 — Broker auth.json mtime stale silencioso

**Síntoma**: tras ~2h idle, broker health endpoint devuelve 503 `auth_file_stale`. Todos los Jobs efímeros fallan en fetch-auth init container. Loop de fails silencioso.

**Causa**: `codex exec` keepalive reporta OK pero NO toca `/state/auth.json` en disco si la sesión Codex sigue válida server-side. mtime nunca se actualiza.

**Fix canon doble**: 
1. **Touch /state/auth.json tras `codex exec` OK** en el keepalive (commit 8b18ce5).
2. **Healthcheck broker + auto-restart en cada tick del cron-dispatcher**: si unhealthy, touch desde keepalive; si sigue mal, rollout restart (commit f3fac018).

### Bug #14 — Watchdog no escuchaba build-sandbox-image

**Síntoma**: Bug #12 (build fail post-merge silencioso) no disparaba el watchdog canon.

**Causa**: watchdog escuchaba solo workflows del pipeline agentic (worker/reviewer/orchestrator/etc), NO los 3 workflows canon de infra: `build-sandbox-image`, `build-orchestrator-image`, `agentic-cron-dispatcher`.

**Fix canon**: añadidos a la lista del watchdog en commit 1c5bd65c.

### Bug #15 — Orchestrator fail huérfano deja Historia "In Progress" sin Change SDD

**Síntoma**: Historia transitiona a "In Progress" cuando orchestrator-dispatch workflow ejecuta `/start`, PERO el Job k8s del orchestrator falla en mitad. Workflow GHA termina succeeded (su trabajo era crear el Job, no esperarlo) → watchdog basado en workflow_run NO se dispara → Historia huérfana, dispatcher la ve "no ready" y nunca la reintenta.

**Fix canon**: step **Recover stale orphan Historias** en cada tick del cron-dispatcher (commit 65c0a0cc). Busca Historias en (To Do, In Progress, In Review) con `updatedAt > 15 min` y las resetea a Backlog. Self-healing canon.

## Onboarding de un producto nuevo (playbook canónico)

Para que un producto nuevo del portfolio (PadelPeak, EvaleIA, Squadwise, etc.) use el patrón Jobs canon. Asume `<producto>-lab` como namespace.

### Pre-requisitos del cluster

1. El namespace `<producto>-lab` existe.
2. El producto tiene su repo GitHub `<owner>/<producto>-lab`.
3. Hay arc-runners disponibles (cualquier label, `arc-runner` por convención).

### Paso 1: identidad bot persistente

1. Crear un usuario GitHub bot del producto (e.g. `kameleon-<producto>-lab-orch`).
2. Generar un **PAT fine-grained** del bot con scope:
   - Repository access: `<producto>-lab` específicamente.
   - Permissions: Contents (R+W), Pull requests (R+W), Issues (R+W), Workflows (R).
3. Verificar el PAT contra el repo:
   ```bash
   curl -sS -u "x-access-token:$TOKEN" \
     https://api.github.com/repos/<owner>/<producto>-lab \
     | jq '.permissions'
   ```
   Espera ver `push: true`.
4. Crear el Secret:
   ```bash
   kubectl create secret generic <producto>-lab-orchestrator-github \
     --from-literal=GITHUB_TOKEN="$TOKEN" \
     -n <producto>-lab
   ```

### Paso 2: dar acceso al broker

1. Etiquetar el namespace:
   ```bash
   kubectl label namespace <producto>-lab \
     canon.kameleonlabs.ai/agentic-jobs=true
   ```
2. Añadir `<producto>-lab` al env `ALLOWED_NAMESPACES` del Deployment del broker (`kameleon-fleet-bootstrap/oauth-broker/k8s/05-deployment.yaml`) y re-apply.
3. Verificar desde un pod del namespace:
   ```bash
   kubectl run test-$RANDOM --rm -i --restart=Never \
     --image=curlimages/curl:8.10.1 -n <producto>-lab \
     -- sh -c 'TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sS -H "Authorization: Bearer $TOKEN" http://oauth-broker.agentic-auth.svc.cluster.local:8080/healthz'
   ```
   Espera `{"ok": true, ...}`.

### Paso 3: copiar `ghcr-pull-secret`

```bash
kubectl get secret ghcr-pull-secret -n kameleonapp-lab -o yaml | \
  sed 's/namespace: kameleonapp-lab/namespace: <producto>-lab/' | \
  kubectl apply -f -
```

### Paso 4: replicar templates + workflows en el repo

1. Copiar `kameleonapp-lab/.github/k8s/agentic-jobs/*.yaml` → `<producto>-lab/.github/k8s/agentic-jobs/`. Editar:
   - `namespace: kameleonapp-lab` → `namespace: <producto>-lab` en cada Job template.
   - `name: kameleonapp-lab-orchestrator-github` → `name: <producto>-lab-orchestrator-github`.

2. Copiar `kameleonapp-lab/.github/workflows/` los 4 workflows canon:
   - `adversarial-review-jobs.yml`
   - `agents-worker.yml`
   - `agents-error-fix.yml`
   - `orchestrator-dispatch.yml`
   Editar `namespace`, `GIT_USERNAME/EMAIL` del bot, `GITHUB_REPOSITORY` references.

3. Copiar el template del prompt orchestrator `.github/orchestrator/dispatch-prompt.md.tpl` adaptado a las convenciones del producto.

### Paso 5: CronJob del producto (opcional)

Si el producto tiene su API KG canon con `/historias/ready`, replicar:

```bash
sed 's/kameleonapp-lab/<producto>-lab/g; s/KAF_/<PROD>_/g; s/kameleon-fleet-bootstrap.*/<...>/' \
  kameleon-fleet-bootstrap/k8s/cronjobs/orchestrator-dispatch-cron.yaml | \
  kubectl apply -f -
```

### Paso 6: humo

1. Crear una Historia ready en la API del producto.
2. Dispatch manual del workflow:
   ```bash
   gh workflow run orchestrator-dispatch.yml \
     --repo <owner>/<producto>-lab \
     --ref dev \
     -f kaf_key=<PROD>-1 \
     -f reason="onboarding smoke"
   ```
3. Verificar Job creado:
   ```bash
   kubectl get jobs -n <producto>-lab -l canon.kameleonlabs.ai/agentic-role=orchestrator
   ```
4. Si el Codex termina OK y crea umbrella issue + PR, el onboarding está completo.

## Vinculado a memorias canon

- `project_oauth_broker_migration_2026_06_09` — registro de la migración.
- `feedback_oauth_broker_for_ephemeral_jobs` — diseño high-level.
- `project_self_hosted_ci_canon` — ARC + buildkitd in-cluster (base sobre la que corren los workflows GHA).
- `feedback_agentic_flow_never_silent` — watchdog canon que monitoriza estos workflows.

## Identidad bot en workflows GHA (patrón canon)

Cuando un workflow GHA del piloto agentic necesita permisos GitHub que
`secrets.GITHUB_TOKEN` no proporciona (`mergePullRequest`, branches
protegidas, admin actions), el patrón canon es **extraer el bot PAT
del cluster Secret** runtime:

```yaml
- name: Mint bot token desde cluster Secret canon
  id: bot-token
  shell: bash
  run: |
    set -euo pipefail
    TOKEN=$(kubectl get secret <producto>-lab-orchestrator-github \
      -n <producto>-lab \
      -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)
    echo "::add-mask::$TOKEN"
    echo "token=$TOKEN" >> "$GITHUB_OUTPUT"

- name: <step que necesita el PAT>
  env:
    GH_TOKEN: ${{ steps.bot-token.outputs.token }}
  run: gh pr merge ...  # o cualquier comando gh
```

**Por qué este patrón es canon (no deuda)**:

1. Bot identity vive en cluster Secret = single source of truth canon
   (sincronizado desde HC Vault vía ExternalSecrets).
2. Workflows GHA self-hosted en arc-runners tienen acceso al cluster por
   defecto.
3. Alternativa GitHub App proper introduce más componentes (App key
   secret, instalaciones por repo, rotación canon) sin ganancia
   funcional real.
4. Portable a cualquier producto del portfolio cambiando solo el nombre
   del Secret.

Ver memoria canon `feedback_jobs_canon_token_extraction_coherent`.
