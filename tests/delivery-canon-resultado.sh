#!/usr/bin/env bash
# OPS-5036 — el veredicto de `delivery-canon` no puede atribuir una causa que
# no ha medido.
#
# El paso `Resultado` juzgaba `steps.build.outcome` con un `if/else` de DOS
# ramas, y ese campo tiene CUATRO valores. Con `skipped` caia en el `else` y
# afirmaba dos cosas falsas de una vez: que el build «fallo» —no llego a
# ejecutarse— y que la causa era «el Dockerfile o el codigo», justo cuando
# quien se habia caido era un paso de la propia receta.
#
# Reportado desde squadwise-platform#387: un `TLS handshake timeout` en
# `Login GHCR` mandaba al autor a revisar su Dockerfile.
#
# Esta prueba EXTRAE el guion real del workflow y lo EJECUTA con los cuatro
# valores. No busca literales: comprueba comportamiento.
set -euo pipefail
cd "$(dirname "$0")/.."

GUION="$(mktemp)"; trap 'rm -f "$GUION"' EXIT
python3 - "$GUION" <<'PY'
import re, sys, yaml
d = yaml.safe_load(open(".github/workflows/delivery-canon.yml"))
run = None
for job in d["jobs"].values():
    for st in job.get("steps") or []:
        if (st.get("name") or "") == "Resultado":
            run = st["run"]
assert run, "no encuentro el paso `Resultado` en delivery-canon.yml"
# las expresiones ${{ }} las resuelve GitHub, no el shell: se neutralizan
open(sys.argv[1], "w").write(re.sub(r"\$\{\{[^}]*\}\}", "IMG", run))
PY

fallos=0
comprobar () { # $1=caso $2=esperado(regex) $3..=env
  local caso="$1" esperado="$2"; shift 2
  local salida; salida="$(env "$@" sh "$GUION" 2>&1 || true)"
  if printf '%s' "$salida" | grep -qE "$esperado"; then
    printf '  ok   %s\n' "$caso"
  else
    printf '  FALLA %s\n       esperaba /%s/\n       obtuvo  %s\n' "$caso" "$esperado" "$salida"
    fallos=$((fallos+1))
  fi
}
no_debe () { # $1=caso $2=prohibido(regex) $3..=env
  local caso="$1" prohibido="$2"; shift 2
  local salida; salida="$(env "$@" sh "$GUION" 2>&1 || true)"
  if printf '%s' "$salida" | grep -qE "$prohibido"; then
    printf '  FALLA %s\n       NO debia contener /%s/\n       obtuvo %s\n' "$caso" "$prohibido" "$salida"
    fallos=$((fallos+1))
  else
    printf '  ok   %s\n' "$caso"
  fi
}

echo "delivery-canon · paso Resultado"
comprobar "build correcto avisa, no error"        'notice'      OUTCOME=success LOGIN_GHCR=success BUILDKITD=success
comprobar "build en rojo SI señala el codigo"     'Dockerfile'  OUTCOME=failure LOGIN_GHCR=success BUILDKITD=success

# El caso de Rubiel: el build no corrio porque fallo el login al registro.
comprobar "skipped nombra el paso culpable"       'Login GHCR'  OUTCOME=skipped LOGIN_GHCR=failure BUILDKITD=skipped
# OJO con estas dos: prohibir la PALABRA no sirve. El mensaje correcto dice
# «falló antes el paso X» y «NO mires tu Dockerfile», y las dos son ciertas. Lo
# que no puede aparecer es la AFIRMACION: que fallara el build, y que la causa
# sea el repositorio del usuario.
no_debe   "skipped NO afirma que el BUILD falló"  'build de [^ ]+ (falló|FALLÓ)' OUTCOME=skipped LOGIN_GHCR=failure BUILDKITD=skipped
no_debe   "skipped NO atribuye la causa al repo"  'es el Dockerfile o el código' OUTCOME=skipped LOGIN_GHCR=failure BUILDKITD=skipped

comprobar "skipped nombra buildkitd si es ese"    'buildkitd'   OUTCOME=skipped LOGIN_GHCR=success BUILDKITD=failure
no_debe   "cancelled NO atribuye la causa al repo" 'es el Dockerfile o el código' OUTCOME=cancelled LOGIN_GHCR=success BUILDKITD=success
comprobar "cancelled se declara sin ejecutar"     'NO se ejecutó' OUTCOME=cancelled LOGIN_GHCR=success BUILDKITD=success

[ "$fallos" -eq 0 ] || { echo "FALLOS: $fallos"; exit 1; }
echo "todo en verde"
