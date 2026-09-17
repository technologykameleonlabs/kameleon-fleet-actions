# Ensayo del paso, con el mismo bash del runner, sobre un arbol de mentira.
set -uo pipefail
fallos=0
ensayo() { # ensayo <nombre> <esperado> <preparar()>
  local nombre=$1 esperado=$2; shift 2
  local raiz; raiz=$(mktemp -d); cd "$raiz"; git init -q .; "$@" ; git add -A >/dev/null 2>&1
  set +e
  bash -c '
    set -euo pipefail
    encontrado=""
    while read -r f; do
      d=$(dirname "$f")
      if [ -e "$d/node_modules/tailwindcss/colors.js" ]; then encontrado="$d"; break; fi
    done < <(git ls-files -- "*/package.json" "package.json")
    if [ -n "$encontrado" ]; then echo "YA: $encontrado"; exit 0; fi
    rango=$(git ls-files -- "*/package.json" "package.json" |  { xargs -r grep -ho "\"tailwindcss\": *\"[^\"]*\"" || true; } | head -1 | sed "s/.*: *\"//; s/\"$//")
    if [ -z "$rango" ]; then echo "SIN RANGO"; exit 1; fi
    echo "INSTALARIA $rango"
  ' >/tmp/ensayo.out 2>&1
  local real=$?
  set -e
  if [ "$real" -ne "$esperado" ]; then echo "FALLO · $nombre (esperaba $esperado, dio $real): $(cat /tmp/ensayo.out)"; fallos=$((fallos+1));
  else echo "ok · $nombre → $(cat /tmp/ensayo.out)"; fi
  cd /; rm -rf "$raiz"
}
prep_instalado() { mkdir -p apps/web/node_modules/tailwindcss; echo '{}' > package.json; echo '{"devDependencies":{"tailwindcss":"^3.4.0"}}' > apps/web/package.json; echo "export default {}" > apps/web/node_modules/tailwindcss/colors.js; }
prep_declarado() { echo '{}' > package.json; mkdir -p apps/web; echo '{"devDependencies":{"tailwindcss":"^3.4.0"}}' > apps/web/package.json; }
prep_sin()       { echo '{"name":"x"}' > package.json; }
ensayo "ya instalado: no instala"        0 prep_instalado
ensayo "declarado pero no instalado"     0 prep_declarado
ensayo "no declarado: ROJO explicito"    1 prep_sin
[ "$fallos" -gt 0 ] && exit 1
echo; echo "el paso detecta los tres casos"
