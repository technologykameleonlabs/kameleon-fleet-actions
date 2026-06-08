# Fase Support canon

Cuarta fase del modelo de trabajo D-D-D-S (Discovery → Definition → Delivery → **Support**).

Hasta esta sesión solo Discovery (catálogos canon en BD + UI tab), Definition (Change SDD) y Delivery (single-pr validado, multi-pr en validación) estaban formalizadas. Support necesita su propio canon ejecutable.

## Qué es Support

Captura el trabajo POST-merge: bugs reportados por usuarios o telemetría, incidencias en producción, mantenimiento correctivo. **NO incluye** el trabajo evolutivo (eso vuelve a Discovery como Outcome nuevo).

Soportar canon en KameleonApp:
- WorkItemType existente `bug` (legado, ya en el sistema).
- WorkItemType nuevo `incident` (a añadir cuando Support madure).

## Canales canon de captura

1. **Reporte manual**: usuario crea WorkItem `bug` o `incident` desde la UI del Project.
2. **Telemetría** (Sentry, Grafana, Prometheus): alerta → webhook → KameleonApp KG endpoint `/api/v1/kg/bugs` que crea automáticamente un WorkItem.
3. **Failed agentic flow**: cuando un PR de la flota falla en producción (e.g. rollback automático), `change-rollback.yml` ya marca el issue como `agent-worker:rolled-back`. Falta: convertir ese estado en un Bug WorkItem nuevo en KG para tracking.

## Pipeline canon Bug → Historia

```
Bug captado (manual o telemetría)
   ↓ (clasificación: severity + área afectada)
WorkItem bug en estado "Open"
   ↓ (triage humano o auto-priority)
WorkItem bug en estado "Triaged" + assignee
   ↓ (si requiere desarrollo)
Auto-genera Historia hija con title=bug.title y description=reference
   ↓
Historia entra al ciclo Definition → Delivery normal
   ↓
PR mergeado → Historia Done → Bug auto-transiciona a Resolved
```

## Endpoints + workflows necesarios

### 1. Endpoint `/api/v1/kg/bugs` (a crear)

```ts
POST /api/v1/kg/bugs
{
  title: string,
  description: string,
  severity: "critical" | "major" | "minor",
  source: "manual" | "sentry" | "grafana" | "agentic-rollback" | "user-report",
  reference?: string,  // URL del evento Sentry / Grafana alert / etc.
  projectKey: string,  // KAF | PPK | EVA | ...
}
→ { ok: true, bug: { key: "KAF-200", workItemId, ... } }
```

### 2. Workflow GHA `bug-to-historia.yml` (a crear)

Triggered en push a dev de un Bug WorkItem que pase a "Triaged". Crea Historia hija automáticamente.

### 3. Webhook Sentry → KG (a configurar)

Sentry tiene webhooks de tipo "Issue alert". Apuntar a `https://my-lab.kameleonlabs.ai/api/v1/kg/bugs` con bearer token.

Payload Sentry → mapping:
- `event.title` → `title`
- `event.message` → `description`
- `event.level` ("error", "fatal", "warning") → `severity` ("major", "critical", "minor")
- `event.url` → `reference`
- `event.project` → `projectKey` (config en Sentry)

### 4. Workflow GHA `agentic-rollback-to-bug.yml` (a crear)

Cuando `change-rollback.yml` ejecuta exitosamente, este workflow:
1. Lee el `change_id` rollback.
2. Para cada issue afectado: crea automáticamente un Bug en KG con reference al issue + rollback PR.
3. Severity = "major" por defecto.
4. Pone a triage humano.

## UI Support (a añadir cuando madure)

- Tab nuevo "Support" en `[id]/page.tsx` paralelo a Discovery.
- Vista: lista de Bugs + Incidents agrupados por estado del workflow.
- Filtros por severity, source, assignee.
- Métricas: MTTR (Mean Time To Resolve), bugs por sprint, % bugs por área.

## Telemetría agregada — Grafana dashboard "Support Health"

Dashboard a crear con paneles:
1. Bugs abiertos por severity (gauge).
2. MTTR rolling 30d (line chart).
3. Bugs por source (pie).
4. Top 10 áreas con más bugs (table).
5. % de Historias que originan Bug en su primera semana post-merge (regression rate).

Source: KG `/api/v1/kg/bugs` + queries SQL agregadas via Prometheus exporter.

## Roadmap implementación

| Hito | Esfuerzo | Bloqueado por |
|---|---|---|
| 1. Endpoint `/api/v1/kg/bugs` en KameleonApp | ~2h | — |
| 2. Webhook Sentry → KG | ~1h | Endpoint listo |
| 3. UI tab Support | ~4h | Endpoint listo |
| 4. Workflow `agentic-rollback-to-bug.yml` | ~2h | Endpoint listo |
| 5. Grafana dashboard "Support Health" | ~2h | Datos en KG |
| 6. Workflow `bug-to-historia.yml` | ~2h | Endpoint + UI |

Total: ~13h, sin dependencia externa.

## Estado canon

| Producto | Endpoint | Webhook Sentry | UI Support | Workflow rollback→bug | Dashboard |
|---|---|---|---|---|---|
| `kameleonapp-lab` | ❌ | ❌ | ❌ | ❌ | ❌ |
| `padelpeak-platform` | ❌ | ❌ | ❌ | ❌ | ❌ |
| `evaleia-app` | ❌ | ❌ | ❌ | ❌ | ❌ |

Roadmap pendiente — Support es la fase menos madura del modelo D-D-D-S. Implementar tras consolidar Definition + Delivery.

## Referencias

- Memoria canon: `project_phases_input_canon_2026_06_05` (cadena Outcome → Métricas).
- `Phase Definition` + `Phase Delivery` foundational docs en `kameleonapp-lab/docs/strategy/phases/`.
