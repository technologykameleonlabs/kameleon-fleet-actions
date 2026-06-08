# Bootstrap canon del piloto agentic en un producto nuevo

Guía paso a paso para aplicar el piloto agentic completo (orchestrator + worker + reviewer + integration-check + change-completed) a un producto KameleonLabs nuevo (PadelPeak, EvaleIA, futuros).

Estado canon a 2026-06-08 tras validación E2E en `kameleonapp-lab` (KAF-17 single-pr cerrado, KAF-19 multi-pr en validación).

## Pre-requisitos

| Recurso | Notas |
|---|---|
| Repo del producto en `technologykameleonlabs/` | Existente |
| Cluster k8s OVH con namespace dedicado para los pods agentic | A crear (ej: `padelpeak-agentic`) |
| Project en KameleonApp con `codePrefix` único de 3 letras (ej `PPK`, `EVA`) y Methodology = `KameleonLabs Canon` | Crear via UI o seed |
| ChatGPT Pro account para OAuth de los workers/orchestrator/reviewer | Tener |
| GitHub App `kameleonlabs-fleet` instalada en el repo | Existente, instalación a confirmar por repo |
| Buildkitd in-cluster (namespace `buildkit-system`) | Ya canon org-level |

## Paso 1 — Project KameleonApp + codePrefix canon

Cada producto necesita su propio Project en KameleonApp donde viven las Historias del piloto. El `codePrefix` define el namespace de keys (ej PPK-1, PPK-2, ...).

```js
// Vía Prisma directo o UI Crear Proyecto:
{
  name: 'PadelPeak Platform',
  codePrefix: 'PPK',
  methodologyId: <id de KameleonLabs Canon>,
  pmUserId: <Julio>,
  tenantId: <Kameleon Labs>,
}
// El trigger auto-seedea las 4 Phase Containers
```

✅ Project PPK ya creado: id `0577f5e0-f2b3-4623-9ba7-599be1219800`.

## Paso 2 — Labels canon en el repo del producto

Necesarias para que los workflows agentic puedan etiquetar issues y PRs según el estado del flow.

```bash
gh label create "agent-worker:pending" --color "FBCA04"
gh label create "agent-worker:in-review" --color "0E8A16"
gh label create "agent-worker:done" --color "1D76DB"
gh label create "agent-worker:failed" --color "B60205"
gh label create "agent-worker:fix-attempt-1" --color "FBCA04"
gh label create "agent-worker:fix-attempt-2" --color "FBCA04"
gh label create "agent-worker:fix-exhausted" --color "B60205"
gh label create "agent-worker:rolled-back" --color "5319E7"
gh label create "kg:deviation-detected" --color "FBCA04"
gh label create "delivery-strategy:single-pr" --color "0366d6"
gh label create "delivery-strategy:multi-pr" --color "0366d6"
```

✅ Labels ya creadas en `padelpeak-platform`.

## Paso 3 — Pods agentic en el cluster

Cada producto tiene su propio pool de pods (aislamiento + escalado independiente). Patrón canon visto en `kameleonapp-lab`:

| Pod | Réplicas | Propósito | PVC |
|---|---|---|---|
| `<prefix>-orchestrator` | 1 | Recibe dispatch del cronjob, ejecuta Codex con prompt SDD, abre Change PR | workspace + auth.json |
| `<prefix>-worker-N` (1, 2, ...) | N | Procesa issues `agent-worker:pending`, abre sub-PR con código | workspace + auth.json + repo cache |
| `<prefix>-reviewer` | 1 | Reviewer adversarial independiente. Lee diffs, valida contra severity catalog | workspace + auth.json |
| `<prefix>-integrator` | 1 | Corre integration-check (lint/typecheck/tests) en sub-PRs | workspace |
| `<prefix>-fixer` | 1 | agents-error-fix loop: intenta auto-fix de integration-check fails | workspace + auth.json |

Cada pod necesita:
- ChatGPT Pro OAuth (device flow propio por pod, persiste en PVC).
- API key `<PREFIX>_*` para hablar con KG endpoint `/api/v1/kg/historias/...`.
- ConfigMap con el prompt template (`dispatch-prompt.md.tpl`).
- ServiceAccount con permisos `pods/exec` para `orchestrator-dispatch-cron`.

**Provisioning**: usar el script `kameleon-fleet-bootstrap/scripts/provision-product.sh` (a crear / adaptar del existente para kameleonapp-lab).

## Paso 4 — Secrets canon

```bash
# En el repo
gh secret set KAF_ORCH_API_KEY --repo <product-repo> --body "kla_..."
gh secret set KAF_WORKER_1_API_KEY --repo <product-repo> --body "kla_..."
gh secret set KAF_WORKER_2_API_KEY --repo <product-repo> --body "kla_..."
gh secret set KUBECONFIG_B64 --repo <product-repo> --body "$(base64 -w0 < ~/.kube/config-prod)"
# (el KL_FLEET_APP_ID y KL_FLEET_APP_PRIVATE_KEY ya están org-level)
```

Por producto, renombrar `KAF_*` a `<PREFIX>_*` (e.g. `PPK_ORCH_API_KEY`).

## Paso 5 — Workflows GHA agentic

Copia desde `kameleonapp-lab/.github/workflows/` con adaptaciones:

| Source | Target | Adaptaciones |
|---|---|---|
| `orchestrator-dispatch.yml` | idem | `KAF` → `<PREFIX>`, namespace `kameleonapp-lab` → `<prefix>-agentic` |
| `agents-worker.yml` | idem | mismo patrón |
| `adversarial-review.yml` | idem | mismo |
| `tasks-to-issues.yml` | idem | mismo |
| `change-completed.yml` | idem | mismo |
| `integration-check.yml` | idem | mismo |
| `agents-error-fix.yml` | idem | mismo |
| `kg-deviation-detector.yml` | idem | mismo |
| `auto-assignment.yml` | idem | mismo |
| `agents-metrics.yml` | idem | mismo |
| `agents-rollback.yml` | idem | mismo |

Todos con `runs-on: arc-runner` (canon self-hosted).

## Paso 6 — k8s CronJob orchestrator-dispatch

En lugar del `schedule:` de GHA (que skipea ticks bajo carga), un CronJob k8s:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: orchestrator-dispatch-cron
  namespace: <prefix>-agentic
spec:
  schedule: "*/1 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: orchestrator-dispatch
          containers:
            - name: dispatcher
              image: bitnami/kubectl:latest
              command:
                - /bin/bash
                - -c
                - |
                  # Curl KG /historias/ready → kubectl exec orchestrator pod con prompt
                  # (ver kameleonapp-lab CronJob canon para referencia completa)
```

Patrón canon en sesión 2026-06-08 (commit `4f96755e` en kameleonapp-lab).

## Paso 7 — Validación E2E

1. Crear Historia de prueba via API:
   ```bash
   curl -X POST $KG_BASE_URL/api/v1/kg/historias \
     -H "Authorization: Bearer $API_KEY" \
     -d '{"title": "STORY: smoke E2E piloto en <prefix>", "description": "...", "storyPoints": 1}'
   ```
2. Marcarla `ready`.
3. Esperar tick CronJob → dispatch → orchestrator genera Change PR → tasks-to-issues → worker sub-PR → adversarial review → integration-check → merge → change-completed marca Historia Done.

Si los 7 hitos del ciclo pasan, el piloto está operativo.

## Estado actual por producto

| Producto | Project KG | Labels | Pods | Secrets | Workflows | CronJob | E2E validado |
|---|---|---|---|---|---|---|---|
| `kameleonapp-lab` | KAF | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ KAF-17 single-pr + KAF-19 multi-pr en validación |
| `padelpeak-platform` | PPK ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | — |
| `evaleia-app` | — | — | — | — | — | — | — |

## Referencias

- Memoria canon: `project_self_hosted_ci_canon`, `project_pilot_e2e_complete_2026_06_05`.
- Workflows fuente: `technologykameleonlabs/kameleonapp-lab/.github/workflows/`.
- Reusable canon CI: `technologykameleonlabs/kameleon-fleet-actions/.github/workflows/build-image-canon.yml`.
