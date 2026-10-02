#!/usr/bin/env bash
# bootstrap.sh — reconstrói o setup do Burp (config + extensões + runtimes + CLI) numa máquina nova.
# Uso: ./bootstrap.sh [all|jython|ext|cli|config|doctor]
# Não commita binários: tudo é baixado/copiado localmente e fica fora do git (ver .gitignore).

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_MANIFEST="$DIR/manifest/extensions.json"
CLI_MANIFEST="$DIR/manifest/cli-tools.json"
BURP_BAPPS="$HOME/.BurpSuite/bapps"

case "$(uname -s)" in
  Darwin) OS=mac ;;
  Linux)  OS=linux ;;
  *)      OS=other ;;
esac
# gerenciador de pacotes do sistema
if   command -v brew   >/dev/null 2>&1; then PKGMGR=brew
elif command -v pacman >/dev/null 2>&1; then PKGMGR=pacman
elif command -v apt    >/dev/null 2>&1; then PKGMGR=apt
else PKGMGR=none; fi

c_ok(){ printf "  \033[32m[ok]\033[0m   %s\n" "$*"; }
c_mis(){ printf "  \033[33m[..]\033[0m   %s\n" "$*"; }
c_err(){ printf "  \033[31m[!!]\033[0m   %s\n" "$*"; }
hdr(){ printf "\n\033[1m== %s ==\033[0m\n" "$*"; }

jqpy(){ python3 -c "import json,sys; d=json.load(open('$1')); $2"; }

# ---------------------------------------------------------------- jython
do_jython(){
  hdr "runtime jython"
  mkdir -p "$DIR/runtimes"
  local dest="$DIR/runtimes/jython-standalone.jar"
  if [ -f "$dest" ]; then c_ok "jython já em runtimes/"; return; fi
  local local_jar
  local_jar=$(ls -1 "$HOME"/Applications/jython-standalone-*.jar 2>/dev/null | head -1)
  if [ -n "$local_jar" ]; then
    cp "$local_jar" "$dest" && c_ok "copiado de $local_jar"; return
  fi
  local ver="2.7.3"
  local url="https://repo1.maven.org/maven2/org/python/jython-standalone/$ver/jython-standalone-$ver.jar"
  c_mis "baixando jython $ver..."
  curl -fL --progress-bar "$url" -o "$dest" && c_ok "jython baixado" || c_err "falha ao baixar jython"
}

# compila uma extensão Java do fonte com javac (sem gradle), embute recursos e empacota
build_java_ext(){ # id name entry
  local id="$1" name="$2" entry="$3"
  command -v javac >/dev/null 2>&1 || { c_err "$name: javac ausente (instale um JDK)"; return 1; }
  local repo srcdir api rel
  repo=$(jqpy "$EXT_MANIFEST" "[print(e['repo']) for e in d['extensions'] if e['id']=='$id']")
  srcdir=$(jqpy "$EXT_MANIFEST" "[print(e['srcdir']) for e in d['extensions'] if e['id']=='$id']")
  api=$(jqpy "$EXT_MANIFEST" "[print(e['api']) for e in d['extensions'] if e['id']=='$id']")
  rel=$(jqpy "$EXT_MANIFEST" "[print(e['release']) for e in d['extensions'] if e['id']=='$id']")
  local work="$DIR/tools/build-src"; mkdir -p "$work"
  local apijar="$work/burp-extender-api-$api.jar"
  [ -f "$apijar" ] || curl -fsSL "https://repo1.maven.org/maven2/net/portswigger/burp/extender/burp-extender-api/$api/burp-extender-api-$api.jar" -o "$apijar" || return 1
  [ -d "$work/$id" ] || git clone --depth 1 "$repo" "$work/$id" >/dev/null 2>&1 || return 1
  local out="$work/out-$id"; rm -rf "$out"; mkdir -p "$out"
  c_mis "$name: compilando do fonte (javac --release $rel)..."
  javac --release "$rel" -cp "$apijar" -d "$out" $(find "$work/$id/$srcdir" -name '*.java') 2>"$work/build-$id.log" || { tail -3 "$work/build-$id.log"; return 1; }
  # embute recursos (png/gif/properties), preservando caminho de pacote
  ( cd "$work/$id/$srcdir" && find . -type f ! -name '*.java' ! -name '*.form' -print0 | tar --null -cf - -T - ) 2>/dev/null | ( cd "$out" && tar -xf - ) 2>/dev/null
  mkdir -p "$DIR/extensions/$id"
  jar cf "$DIR/extensions/$id/$entry" -C "$out" . && c_ok "$name (compilado)"
}

# ---------------------------------------------------------------- extensões
do_ext(){
  hdr "extensões do Burp (em extensions/<id>/)"
  while IFS=$'\t' read -r id name typ entry source; do
    [ -z "$id" ] && continue
    local tdir="$DIR/extensions/$id"
    local target="$tdir/$entry"
    if [ "$entry" != "None" ] && [ -f "$target" ]; then c_ok "$name"; continue; fi
    case "$source" in
      local-cache)
        if [ -d "$BURP_BAPPS/$id" ]; then
          mkdir -p "$tdir"; cp -r "$BURP_BAPPS/$id/." "$tdir/"
          [ -f "$target" ] && c_ok "$name (cache ~/.BurpSuite/bapps)" || c_err "$name: copiado mas '$entry' não achado"
        else c_mis "$name: sem cache local — instale 1x pela BApp Store e rode de novo (ou commite extensions/$id/)"; fi ;;
      download)
        mkdir -p "$tdir"
        local okall=1
        while IFS=$'\t' read -r fpath furl; do
          [ -z "$fpath" ] && continue
          curl -fsSL "$furl" -o "$tdir/$fpath" || { okall=0; c_err "$name: falha em $fpath"; }
        done < <(jqpy "$EXT_MANIFEST" "[print('\t'.join([f['path'],f['url']])) for e in d['extensions'] if e['id']=='$id' for f in e.get('files',[])]")
        [ "$okall" = 1 ] && c_ok "$name (download)" ;;
      build)
        build_java_ext "$id" "$name" "$entry" || c_err "$name: build falhou" ;;
      store-only)
        c_mis "$name: sem fonte OSS — instalar pela BApp Store" ;;
    esac
  done < <(jqpy "$EXT_MANIFEST" "[print('\t'.join([str(e.get(k)) for k in ('id','name','type','entry','source')])) for e in d['extensions']]")
}

# ---------------------------------------------------------------- CLI
ensure_pipx(){
  command -v pipx >/dev/null 2>&1 && return 0
  python3 -m pip install --user --break-system-packages pipx >/dev/null 2>&1
  python3 -m pipx ensurepath >/dev/null 2>&1 || true
  # aliases não são expandidos em scripts não-interativos; usa uma função como fallback
  command -v pipx >/dev/null 2>&1 || pipx(){ python3 -m pipx "$@"; }
}

install_release(){ # repo asset_match name
  local repo="$1" match="$2" name="$3"
  local url
  url=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
        | python3 -c "import json,sys;r=json.load(sys.stdin);print(next((a['browser_download_url'] for a in r['assets'] if '$match' in a['name']),''))")
  [ -z "$url" ] && { c_err "$name: asset '$match' não achado no release"; return 1; }
  local tmp; tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/pkg"
  case "$url" in
    *.tar.gz|*.tgz) tar xzf "$tmp/pkg" -C "$tmp" ;;
    *.zip) unzip -q "$tmp/pkg" -d "$tmp" ;;
    *.gz) gunzip -c "$tmp/pkg" > "$tmp/$name" ;;
    *) cp "$tmp/pkg" "$tmp/$name" ;;
  esac
  local found; found=$(find "$tmp" -type f -name "$name" | head -1)
  [ -z "$found" ] && found=$(find "$tmp" -maxdepth 1 -type f ! -name pkg | head -1)
  install -m755 "$found" "$DIR/bin/$name" && c_ok "$name -> bin/$name"
  rm -rf "$tmp"
}

sys_install(){ # nome pkg
  local name="$1" pkg="$2"
  [ -z "$pkg" ] && { c_err "$name: sem pacote para '$PKGMGR'"; return 1; }
  case "$PKGMGR" in
    brew)   brew install "$pkg" >/dev/null 2>&1 && c_ok "$name (brew)" || c_err "$name: 'brew install $pkg' falhou" ;;
    pacman) if command -v sudo >/dev/null 2>&1; then sudo pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1 && c_ok "$name (pacman)" || c_err "$name: rode 'sudo pacman -S $pkg'"; else c_err "$name: rode 'sudo pacman -S $pkg'"; fi ;;
    apt)    if command -v sudo >/dev/null 2>&1; then sudo apt-get install -y "$pkg" >/dev/null 2>&1 && c_ok "$name (apt)" || c_err "$name: rode 'sudo apt-get install $pkg'"; else c_err "$name: rode 'sudo apt-get install $pkg'"; fi ;;
    *)      c_err "$name: sem gerenciador de pacotes (brew/pacman/apt)" ;;
  esac
}

do_cli(){
  hdr "CLI tools  (OS=$OS, pkgmgr=$PKGMGR)"
  mkdir -p "$DIR/bin"
  while IFS=$'\t' read -r name check method pkg repo asset entry pbrew ppac papt rrepo rasset; do
    [ -z "$name" ] && continue
    if command -v "$check" >/dev/null 2>&1; then c_ok "$name (já instalado)"; continue; fi
    case "$method" in
      go)       command -v go >/dev/null 2>&1 && { c_mis "go install $name..."; GOBIN="" go install "$pkg" >/dev/null 2>&1 && c_ok "$name" || c_err "$name: go install falhou"; } || c_err "$name: go ausente" ;;
      pipx)     ensure_pipx; pipx install "$pkg" >/dev/null 2>&1 && c_ok "$name" || c_err "$name: pipx install falhou" ;;
      cargo)    # no Linux usa release pré-compilado (rápido); senão compila via cargo (cross-platform)
                if [ "$OS" = linux ] && [ -n "$rasset" ]; then install_release "$rrepo" "$rasset" "$name"
                elif command -v cargo >/dev/null 2>&1; then c_mis "cargo install $name (compila)..."; cargo install "$pkg" >/dev/null 2>&1 && c_ok "$name (cargo)" || c_err "$name: cargo install falhou"
                else c_err "$name: precisa de cargo (rustup) ou release pré-compilado"; fi ;;
      release)  install_release "$repo" "$asset" "$name" ;;
      gitclone) d="$DIR/tools/$name"; mkdir -p "$DIR/tools"; [ -d "$d" ] || git clone --depth 1 "$repo" "$d" >/dev/null 2>&1; printf '#!/usr/bin/env bash\nexec python3 "%s/%s" "$@"\n' "$d" "$entry" > "$DIR/bin/$name"; chmod +x "$DIR/bin/$name"; c_ok "$name -> bin/$name (clone)" ;;
      system)   case "$PKGMGR" in brew) sys_install "$name" "$pbrew";; pacman) sys_install "$name" "$ppac";; apt) sys_install "$name" "$papt";; *) c_err "$name: instale manualmente";; esac ;;
      *) c_err "$name: método '$method' desconhecido" ;;
    esac
  done < <(jqpy "$CLI_MANIFEST" "[print('\t'.join([t.get(k,'') for k in ('name','check','method','pkg','repo','asset_match','entry','pkg_brew','pkg_pacman','pkg_apt','release_repo','release_asset_linux')])) for t in d['tools']]")
}

# ---------------------------------------------------------------- config
do_config(){
  hdr "render config/user-config.json (a partir do manifest)"
  mkdir -p "$DIR/config"
  DIR="$DIR" python3 - "$EXT_MANIFEST" <<'PY'
import json, os, sys
DIR=os.environ["DIR"]
man=json.load(open(sys.argv[1]))
jy=os.path.join(DIR,"runtimes","jython-standalone.jar")
exts=[]
skipped=[]
for e in man["extensions"]:
    entry=e.get("entry")
    if not entry: skipped.append(e["name"]); continue
    f=os.path.join(DIR,"extensions",e["id"],entry)
    if not os.path.isfile(f): skipped.append(e["name"]); continue
    exts.append({
        "auto_reload": False, "errors": "ui", "output": "ui", "use_ai": False,
        "loaded": True, "name": e["name"],
        "extension_type": e["type"],
        "extension_file": f,
    })
cfg={"user_options":{"extender":{
    "extensions": exts,
    "python": {"location_of_jython_standalone_jar_file": jy},
    "ruby": {"location_of_jruby_jar_file": ""},
}}}
out=os.path.join(DIR,"config","user-config.json")
json.dump(cfg,open(out,"w"),indent=2)
print(f"  gerado {out}")
print(f"  extensões carregadas: {len(exts)}  -> "+", ".join(x["name"] for x in exts))
if skipped: print(f"  fora (arquivo ausente): "+", ".join(skipped))
PY
  c_ok "config pronta"
}

# ---------------------------------------------------------------- doctor
do_doctor(){
  hdr "doctor / PATH"
  echo "  Garanta no PATH (ex.: ~/.config/fish/config.fish):"
  echo "    set -gx PATH \$PATH $DIR/bin \$(go env GOPATH 2>/dev/null)/bin ~/.local/bin"
  echo
  echo "  Atenção: você tem um alias 'gau=git add --update' que mascara o gau real."
  echo "  Rode o Burp com:  $DIR/launch.sh"
}

case "${1:-all}" in
  all)     do_jython; do_ext; do_cli; do_config; do_doctor ;;
  jython)  do_jython ;;
  ext)     do_ext ;;
  cli)     do_cli ;;
  config)  do_config ;;
  doctor)  do_doctor ;;
  *) echo "uso: $0 [all|jython|ext|cli|config|doctor]"; exit 1 ;;
esac
