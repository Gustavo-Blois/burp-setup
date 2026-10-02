#!/usr/bin/env bash
# launch.sh — sobe o Burp com a config portável deste repo (não toca em ~/.BurpSuite).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$DIR/config/user-config.json"

# localiza o burpsuite.jar (ajuste BURP_JAR no ambiente se necessário)
BURP_JAR="${BURP_JAR:-}"
if [ -z "$BURP_JAR" ]; then
  for c in \
    "$HOME/BurpSuite/burpsuite.jar" "$HOME/BurpSuite/burpsuite_pro.jar" \
    /opt/BurpSuite*/burpsuite*.jar \
    "/Applications/Burp Suite Professional.app/Contents/Resources/app/burpsuite_pro.jar" \
    "/Applications/Burp Suite Community Edition.app/Contents/Resources/app/burpsuite_community.jar" \
    "$HOME/Applications/Burp Suite Professional.app/Contents/Resources/app/"*.jar; do
    [ -f "$c" ] && { BURP_JAR="$c"; break; }
  done
fi
[ -f "$BURP_JAR" ] || { echo "burpsuite jar não encontrado — exporte BURP_JAR=/caminho/para/burpsuite.jar"; exit 1; }
[ -f "$CFG" ] || { echo "config ausente — rode ./bootstrap.sh config primeiro"; exit 1; }

# escolhe o java: o do sistema, ou o JRE embutido no .app do Burp (macOS)
JAVA_BIN="$(command -v java || true)"
if [ -z "$JAVA_BIN" ]; then
  bundled=$(find "${BURP_JAR%/Resources/*}" -name java -path '*/bin/java' 2>/dev/null | head -1)
  [ -n "$bundled" ] && JAVA_BIN="$bundled"
fi
[ -n "$JAVA_BIN" ] || { echo "java não encontrado no PATH nem no .app — instale um JDK ou exporte JAVA_BIN"; exit 1; }

exec "$JAVA_BIN" -jar "$BURP_JAR" --user-config-file="$CFG" "$@"
