#!/usr/bin/env bash
# Publica una versión de YabaiBar: compila la Release firmada, hace el DMG, lo sube a GitHub Releases y actualiza el
# cask de Homebrew (jerickgm89/homebrew-tap).
#
#   scripts/release.sh 3.0.0 --dry-run   Todo menos publicar: deja el DMG y las notas en build/release
#   scripts/release.sh 3.0.0             Igual, y pide confirmación antes de hacer commit, tag, push y release
#   scripts/release.sh 3.0.0 --yes       Sin preguntar (cuando ya se confirmó)
#
# Necesita Xcode, XcodeGen, gh con sesión y un certificado de firma de código de confianza en el llavero
# (SIGN_IDENTITY, por defecto "YabaiBar Release"). Todas las versiones deben firmarse con el mismo: el permiso de
# Accesibilidad y la aprobación de Gatekeeper dependen de él.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=YabaiBar
REPO=jerickgm89/yabaiDynamicIsland
TAP_REPO=jerickgm89/homebrew-tap
CASK=yabaibar
SIGN_IDENTITY="${SIGN_IDENTITY:-YabaiBar Release}"
OUT="$ROOT/build/release"
DERIVED="$OUT/DerivedData.noindex"

usage() { echo "Uso: scripts/release.sh <versión, p. ej. 3.0.0> [--dry-run | --yes]" >&2; exit 2; }
step() { printf '\n==> %s\n' "$*"; }
warn() { echo "Aviso: $*" >&2; }
fail() { echo "Error: $*" >&2; exit 1; }

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
mode="${2:-}"
[[ -z "$mode" || "$mode" == "--dry-run" || "$mode" == "--yes" ]] || usage
dry_run=false; [[ "$mode" == "--dry-run" ]] && dry_run=true
tag="v$version"
dmg="$OUT/$APP-$version.dmg"
notes="$OUT/notas-$version.md"

cd "$ROOT"

# En algunas máquinas xcode-select apunta a CommandLineTools
if ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  xcodebuild -version >/dev/null 2>&1 || fail "no se encuentra Xcode"
fi
command -v xcodegen >/dev/null || fail "falta xcodegen: brew install xcodegen"

has_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$1\""; }

step "Comprobaciones"
grep -q "^## \[$version\]" CHANGELOG.md || fail "CHANGELOG.md no tiene la sección \"## [$version]\""
if ! has_identity "$SIGN_IDENTITY"; then
  if $dry_run && has_identity "YabaiBar Dev"; then
    warn "no hay un certificado \"$SIGN_IDENTITY\" válido: en seco se firma con \"YabaiBar Dev\""
    SIGN_IDENTITY="YabaiBar Dev"
  else
    fail "no hay un certificado \"$SIGN_IDENTITY\" válido para firmar código (ver README, \"Publicar una versión\")"
  fi
fi
expiry="$(security find-certificate -c "$SIGN_IDENTITY" -p | openssl x509 -noout -enddate | cut -d= -f2)"
echo "Firma: $SIGN_IDENTITY (caduca: $expiry)"
security find-certificate -c "$SIGN_IDENTITY" -p | openssl x509 -noout -checkend $((60 * 60 * 24 * 30)) >/dev/null \
  || fail "el certificado caduca en menos de 30 días"
if ! $dry_run; then
  [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || fail "hay que publicar desde main"
  [[ -z "$(git status --porcelain)" ]] || fail "hay cambios sin commit"
  gh auth status >/dev/null 2>&1 || fail "gh no tiene sesión: gh auth login"
  git fetch --quiet origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main no coincide con origin/main"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    fail "el tag $tag ya existe"
  fi
fi
current_build="$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "([0-9]+)"/\1/p' project.yml)"
build_number=$((current_build + 1))
echo "Versión $version (compilación $build_number)"

step "Tests"
xcodegen generate --quiet
xcodebuild -quiet -project "$APP.xcodeproj" -scheme "$APP" -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$ROOT/build/DerivedData.noindex" -configuration Debug test 2>&1 | awk 'length($0) < 2000'

step "Compilación Release firmada"
rm -rf "$DERIVED"
xcodebuild -quiet -project "$APP.xcodeproj" -scheme "$APP" -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" -configuration Release \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  clean build 2>&1 | awk 'length($0) < 2000'
app="$DERIVED/Build/Products/Release/$APP.app"
[[ -d "$app" ]] || fail "no se generó $app"

step "Verificación"
codesign --verify --deep --strict "$app" || fail "la firma no es válida"
codesign -dr - "$app" 2>&1 | grep -q "certificate leaf" || fail "el requisito de firma no usa el certificado (¿firma ad-hoc?)"
for binary in "$app/Contents/MacOS/$APP" "$app/Contents/Frameworks/MediaRemoteAdapter.framework/MediaRemoteAdapter"; do
  archs="$(lipo -archs "$binary")"
  [[ "$archs" == "arm64" ]] || fail "$(basename "$binary") es $archs, no solo arm64"
done
plist_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$plist_version" == "$version" ]] || fail "Info.plist dice $plist_version"
# Por los símbolos: los textos cortos, como "pomodoro-demo", Swift los guarda dentro de las instrucciones y strings no
# los ve. Sin -q: con pipefail, si grep saliera al primer acierto, nm moriría con SIGPIPE y el if no lo vería
if nm "$app/Contents/MacOS/$APP" | grep -E 'stressTest|startDemo|saveSnapshot' >/dev/null; then fail "la Release lleva el código de DEBUG"; fi
echo "Firma, arm64, versión y sin DEBUG: bien"

step "DMG"
stage="$OUT/dmg"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
ditto "$app" "$stage/$APP.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "$APP $version" -srcfolder "$stage" -format ULFO -ov "$dmg"
codesign --sign "$SIGN_IDENTITY" "$dmg"
codesign --verify "$dmg" || fail "la firma del DMG no es válida"
hdiutil verify -quiet "$dmg" || fail "el DMG está dañado"
# Se monta para revisar lo que lleva: en una carpeta temporal fuera de Documents, sin -quiet (si falla, se ve por
# qué) y con reintentos, porque una vez el montaje falló sin motivo aparente y la imagen quedó adjuntada sin montar
mount="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/yabaibar-dmg.XXXXXX")" && pwd -P)"
device=""
release_image() {
  if [[ -n "$device" ]]; then hdiutil detach -quiet -force "$device" 2>/dev/null || true; fi
  device=""
}
trap 'release_image; rmdir "$mount" 2>/dev/null || true' EXIT
mounted=false
for attempt in 1 2 3; do
  attach_output="$(hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" 2>&1)" || true
  device="$(awk '/^\/dev\/disk[0-9]+[[:space:]]/ { print $1; exit }' <<<"$attach_output")"
  if mount | grep -F " on $mount (" >/dev/null; then mounted=true; break; fi
  warn "no se pudo montar el DMG (intento $attempt de 3): $(grep -v '^/dev/' <<<"$attach_output" | tail -1)"
  release_image
  sleep 2
done
$mounted || fail "no se pudo montar el DMG para revisarlo"
[[ -L "$mount/Applications" ]] || fail "al DMG le falta el enlace a Aplicaciones"
codesign --verify --deep --strict "$mount/$APP.app" || fail "la app del DMG no pasa codesign"
release_image
rmdir "$mount" 2>/dev/null || true
trap - EXIT
rm -rf "$stage" "$OUT/montado"
echo "Contenido del DMG: bien"
sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
echo "$dmg"
echo "SHA-256: $sha"

step "Notas"
changes="$OUT/cambios-$version.md"
awk -v header="## [$version]" '
  index($0, header) == 1 { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' CHANGELOG.md | sed -e '/./,$!d' > "$changes"
awk -v changes="$changes" '{
  if ($0 == "{{CHANGES}}") { while ((getline line < changes) > 0) print line }
  else print
}' packaging/release-notes.md | sed -e "s/{{VERSION}}/$version/g" -e "s/{{SHA256}}/$sha/g" > "$notes"
rm -f "$changes"
echo "$notes"

if $dry_run; then
  step "En seco: no se publica nada"
  echo "Para publicar: scripts/release.sh $version"
  exit 0
fi

step "Publicar"
cat <<EOF
Se va a:
  1. poner $version (compilación $build_number) en project.yml y hacer el commit "Versión $version";
  2. crear el tag $tag y subir main y el tag a origin;
  3. crear el release $tag en $REPO con $(basename "$dmg") y las notas de $notes;
  4. actualizar Casks/$CASK.rb en $TAP_REPO (version y sha256) y subirlo.
EOF
if [[ "$mode" != "--yes" ]]; then
  read -r -p "Escribe \"publicar\" para seguir: " answer
  [[ "$answer" == "publicar" ]] || fail "cancelado: no se ha publicado nada"
fi

sed -i '' -E \
  -e "s/^( *MARKETING_VERSION: )\"[^\"]*\"/\1\"$version\"/" \
  -e "s/^( *CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\1\"$build_number\"/" project.yml
git add project.yml
git commit --quiet -m "Versión $version"
git tag -a "$tag" -m "$APP $version"
git push --quiet origin main "$tag"
if ! gh release create "$tag" "$dmg" --repo "$REPO" --title "$APP $version" --notes-file "$notes" --verify-tag; then
  # El tag ya está subido: volver a lanzar el script fallaría en "el tag ya existe"
  fail "no se pudo crear el release. Termínalo a mano:
  gh release create $tag \"$dmg\" --repo $REPO --title \"$APP $version\" --notes-file \"$notes\" --verify-tag
  y actualiza el cask de $TAP_REPO (version $version, sha256 $sha)"
fi
echo "Release: https://github.com/$REPO/releases/tag/$tag"

step "Tap de Homebrew"
tap_dir="$OUT/homebrew-tap"
rm -rf "$tap_dir"
if ! gh repo clone "$TAP_REPO" "$tap_dir" -- --quiet 2>/dev/null; then
  warn "no se pudo clonar $TAP_REPO: actualiza el cask a mano (version $version, sha256 $sha)"
  exit 0
fi
cask_file="$tap_dir/Casks/$CASK.rb"
if [[ ! -f "$cask_file" ]]; then
  mkdir -p "$(dirname "$cask_file")"
  sed '1,2d' packaging/homebrew/$CASK.rb > "$cask_file"
fi
sed -i '' -E \
  -e "s/^(  version )\"[^\"]*\"/\1\"$version\"/" \
  -e "s/^(  sha256 )\"[^\"]*\"/\1\"$sha\"/" "$cask_file"
git -C "$tap_dir" add -A
git -C "$tap_dir" commit --quiet -m "$CASK $version"
git -C "$tap_dir" push --quiet
echo "Cask actualizado: brew install --cask jerickgm89/tap/$CASK"
