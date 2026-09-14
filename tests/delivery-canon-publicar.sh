#!/usr/bin/env bash
# OPS-6605 / OPS-5359 — `delivery-canon` publica SOLO desde la rama principal
# o un tag.
#
# El paso `Metadatos y tags` decidia `push = (event != pull_request)`. Con esa
# regla un `gh workflow run ci.yml --ref <rama-de-PR>` (workflow_dispatch) es
# un push a GHCR: el 14-sep-2026, en squadwise-platform, publico `dev-<sha>` y
# `dev-latest` de una rama de PR; argocd-image-updater (newest-build) desplego
# en dev un commit que NO estaba en main (78f899df) y dev sirvio codigo de una
# rama durante horas.
#
# Esta prueba EXTRAE el guion real del paso y lo EJECUTA con las combinaciones
# evento/ref que importan. No busca literales: lee `push=` del GITHUB_OUTPUT.
set -euo pipefail
cd "$(dirname "$0")/.."

GUION="$(mktemp)"; SALIDA="$(mktemp)"; trap 'rm -f "$GUION" "$SALIDA"' EXIT
python3 - "$GUION" <<'PY'
import re, sys, yaml
d = yaml.safe_load(open(".github/workflows/delivery-canon.yml"))
run = None
for job in d["jobs"].values():
    for st in job.get("steps") or []:
        if (st.get("name") or "") == "Metadatos y tags":
            run = st["run"]
assert run, "no encuentro el paso `Metadatos y tags` en delivery-canon.yml"
# las expresiones ${{ }} las resuelve GitHub, no el shell: se neutralizan
open(sys.argv[1], "w").write(re.sub(r"\$\{\{[^}]*\}\}", "IMG", run))
PY

fallos=0
caso () { # $1=nombre $2=push esperado (true|false) $3=evento $4=ref $5=rama principal
  local nombre="$1" esperado="$2" evento="$3" ref="$4" rama="$5"
  : > "$SALIDA"
  local log; log="$(env -i PATH="$PATH" HOME="$HOME" \
      GITHUB_OUTPUT="$SALIDA" GITHUB_SHA=78f899df0000000000000000000000000000abcd \
      IMAGE=ghcr.io/x/y PREFIX_IN=dev REF="$ref" REF_NAME="${ref#refs/*/}" BARE=false \
      EVENT="$evento" DEFAULT_BRANCH="$rama" \
      bash "$GUION" 2>&1 || true)"
  local push; push="$(sed -n 's/^push=//p' "$SALIDA")"
  if [ "$push" = "$esperado" ]; then
    printf '  ok   %s (push=%s)\n' "$nombre" "$push"
  else
    printf '  FALLA %s\n       esperaba push=%s, obtuvo push=%s\n       log: %s\n' "$nombre" "$esperado" "${push:-<vacio>}" "$log"
    fallos=$((fallos+1))
  fi
  # Cuando no publica fuera de una PR, tiene que DECIRLO (no un silencio).
  if [ "$esperado" = "false" ] && [ "$evento" != "pull_request" ]; then
    if printf '%s' "$log" | grep -q '::notice.*SIN publicar'; then
      printf '  ok   %s avisa con ::notice\n' "$nombre"
    else
      printf '  FALLA %s NO avisa con ::notice que no publica\n       log: %s\n' "$nombre" "$log"
      fallos=$((fallos+1))
    fi
  fi
}

echo "delivery-canon · paso Metadatos y tags (publicar)"
# El incidente: dispatch sobre una rama de PR.
caso "dispatch sobre refs/heads/feature/x NO publica"  false workflow_dispatch refs/heads/feature/x main
caso "dispatch sobre la rama principal publica"        true  workflow_dispatch refs/heads/main      main
caso "dispatch sobre main con principal=dev NO publica" false workflow_dispatch refs/heads/main     dev
caso "push a la rama principal publica"                true  push              refs/heads/main      main
caso "push a la principal (dev) publica"               true  push              refs/heads/dev       dev
caso "push a otra rama NO publica"                     false push              refs/heads/release/1 main
caso "push de tag publica"                             true  push              refs/tags/v1.2.3     main
caso "pull_request NO publica"                         false pull_request      refs/pull/42/merge   main

[ "$fallos" -eq 0 ] || { echo "FALLOS: $fallos"; exit 1; }
echo "todo en verde"
