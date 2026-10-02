#!/usr/bin/env bash
# launch.sh — sobe o Burp com a config portável deste repo (não toca em ~/.BurpSuite).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/config/user-config.json"

# localiza o burpsuite.jar (ajuste BURP_JAR no ambiente se necessário)
BURP_JAR="${BURP_JAR:-}"
if [ -z "$BURP_JAR" ]; then
  # 1) nomes/locais conhecidos (rápido) — cobre as variações de branding do
  #    instalador da PortSwigger ("Burp Suite.app" unificado, ou as antigas
  #    "Professional"/"Community Edition") em mac e linux.
  for c in \
    "$HOME/BurpSuite/burpsuite.jar" "$HOME/BurpSuite/burpsuite_pro.jar" "$HOME/BurpSuite/burpsuite_community.jar" \
    /opt/BurpSuite*/burpsuite*.jar /opt/burpsuite*/burpsuite*.jar \
    /Applications/"Burp Suite"*.app/Contents/Resources/app/burpsuite*.jar \
    "$HOME/Applications/Burp Suite"*.app/Contents/Resources/app/burpsuite*.jar; do
    [ -f "$c" ] && { BURP_JAR="$c"; break; }
  done
fi
if [ -z "$BURP_JAR" ] && command -v mdfind >/dev/null 2>&1; then
  # 2) macOS: Spotlight já tem isso indexado, é instantâneo
  BURP_JAR=$(mdfind "kMDItemFSName == 'burpsuite*.jar'" 2>/dev/null | head -1)
fi
if [ -z "$BURP_JAR" ]; then
  # 3) fallback: busca em disco nos lugares mais prováveis
  BURP_JAR=$(find /Applications "$HOME/Applications" /opt "$HOME/BurpSuite" "$HOME/.local/share" \
    -maxdepth 6 -iname 'burpsuite*.jar' 2>/dev/null | head -1)
fi
[ -n "$BURP_JAR" ] && [ -f "$BURP_JAR" ] || { echo "burpsuite jar não encontrado — instale o Burp Suite (https://portswigger.net/burp) ou exporte BURP_JAR=/caminho/para/burpsuite.jar"; exit 1; }
[ -f "$CFG" ] || { echo "config ausente — rode ./bootstrap.sh config primeiro"; exit 1; }

# escolhe o java: o do sistema, ou o JRE embutido no .app do Burp (macOS)
JAVA_BIN="$(command -v java || true)"
if [ -z "$JAVA_BIN" ]; then
  bundled=$(find "${BURP_JAR%/Resources/*}" -name java -path '*/bin/java' 2>/dev/null | head -1)
  [ -n "$bundled" ] && JAVA_BIN="$bundled"
fi
[ -n "$JAVA_BIN" ] || { echo "java não encontrado no PATH nem no .app — instale um JDK ou exporte JAVA_BIN"; exit 1; }

exec "$JAVA_BIN" -jar "$BURP_JAR" --user-config-file="$CFG" "$@"
