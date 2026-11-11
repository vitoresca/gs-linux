#!/usr/bin/env bash
# Global Solution - Servicos Linux (AlmaLinux 9/10)
# Instala e configura DNS autoritativo BIND e Apache com template HTML externo.
# Uso: sudo bash gs_dns_web.sh
# IMPORTANTE: execute em VM de laboratorio. Altera /etc/named.conf e /var/www/html.
set -Eeuo pipefail

LOG=/var/log/gs_dns_web.log
if (( EUID != 0 )); then echo '[ERRO] Execute com sudo: sudo bash gs_dns_web.sh' >&2; exit 1; fi
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[ERRO] Falha na linha $LINENO. Consulte $LOG" >&2' ERR
info(){ printf '\n[INFO] %s\n' "$*"; }
aviso(){ printf '\n[AVISO] %s\n' "$*"; }
falha(){ printf '\n[ERRO] %s\n' "$*" >&2; exit 1; }
pergunta_sim(){ local r; read -r -p "$1 [s/N]: " r; [[ "${r,,}" == s || "${r,,}" == sim ]]; }
valida_ipv4(){ local ip=$1 p; [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; local -a oct; IFS=. read -r -a oct <<< "$ip"; for p in "${oct[@]}"; do (( 10#$p <= 255 )) || return 1; done; }
valida_dominio(){ [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; }
valida_nome(){ [[ "$1" == @ ]] || [[ "$1" =~ ^[a-zA-Z0-9_*-]+(\.[a-zA-Z0-9_*-]+)*$ ]]; }
valida_ipv6(){ [[ "$1" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$1" == *:* ]]; }
normaliza_alvo(){ local a=${1%.}; [[ "$a" == *.* ]] && printf '%s.\n' "$a" || printf '%s\n' "$a"; }

printf '\n=== GLOBAL SOLUTION: DNS BIND + APACHE ===\n'
echo 'Este script instala pacotes, configura DNS e publica um site HTML.'
echo 'ATENCAO: substitui o conteudo de /var/www/html e altera o BIND.'
pergunta_sim 'Deseja continuar?' || { echo 'Cancelado.'; exit 0; }

info '1/7 - Verificando sistema e conectividade'
[[ -f /etc/os-release ]] || falha 'Sistema sem /etc/os-release.'
. /etc/os-release
[[ " ${ID:-} ${ID_LIKE:-} " == *almalinux* || " ${ID:-} ${ID_LIKE:-} " == *rhel* ]] || falha 'Script destinado a AlmaLinux/RHEL.'
command -v dnf >/dev/null || falha 'dnf nao encontrado.'

IP_PADRAO=$(hostname -I 2>/dev/null | awk '{print $1}')
while :; do
  read -r -p 'Dominio (ex.: empresa.test): ' DOMINIO
  DOMINIO=${DOMINIO,,}; DOMINIO=${DOMINIO%.}
  valida_dominio "$DOMINIO" && break
  aviso 'Dominio invalido; tente novamente.'
done
while :; do
  read -r -p "IPv4 do servidor [${IP_PADRAO:-sem padrao}]: " IP_SERVIDOR
  IP_SERVIDOR=${IP_SERVIDOR:-$IP_PADRAO}
  valida_ipv4 "$IP_SERVIDOR" && break
  aviso 'IPv4 invalido; tente novamente.'
done

REGISTROS=()
TESTES_NOME=()
TESTES_TIPO=()
info 'Registros automaticos: NS ns1, A ns1 e A @.'
echo 'Registros adicionais: A, AAAA, CNAME, MX ou TXT. ENTER termina.'
while :; do
  read -r -p 'Tipo de registro (ou ENTER): ' TIPO
  TIPO=${TIPO^^}; [[ -z "$TIPO" ]] && break
  case "$TIPO" in A|AAAA|CNAME|MX|TXT) ;; *) aviso 'Tipo nao suportado.'; continue;; esac
  read -r -p 'Nome do registro (ex.: www, mail, @): ' NOME
  NOME=${NOME:-@}
  valida_nome "$NOME" || { aviso 'Nome invalido.'; continue; }
  case "$TIPO" in
    A) read -r -p 'IPv4: ' VALOR; valida_ipv4 "$VALOR" || { aviso 'IPv4 invalido.'; continue; } ;;
    AAAA) read -r -p 'IPv6: ' VALOR; valida_ipv6 "$VALOR" || { aviso 'IPv6 invalido.'; continue; } ;;
    CNAME) read -r -p 'Destino (ex.: ns1 ou host.exemplo.com): ' VALOR; valida_nome "$VALOR" || { aviso 'Destino invalido.'; continue; }; [[ "$NOME" != @ && "$NOME" != ns1 ]] || { aviso 'CNAME nao pode substituir @ ou ns1.'; continue; }; VALOR=$(normaliza_alvo "$VALOR") ;;
    MX) read -r -p 'Prioridade (ex.: 10): ' PRIO; [[ "$PRIO" =~ ^[0-9]{1,5}$ ]] && (( 10#$PRIO <= 65535 )) || { aviso 'Prioridade invalida.'; continue; }; read -r -p 'Servidor de email (ex.: mail): ' ALVO; valida_nome "$ALVO" && [[ "$ALVO" != @ ]] || { aviso 'Destino invalido.'; continue; }; VALOR="$PRIO $(normaliza_alvo "$ALVO")" ;;
    TXT) read -r -p 'Texto (max. 255 caracteres ASCII, sem aspas): ' VALOR; [[ -n "$VALOR" && ${#VALOR} -le 255 && "$VALOR" != *'"'* && "$VALOR" != *'\\'* ]] || { aviso 'TXT invalido.'; continue; }; VALOR="\"$VALOR\"" ;;
  esac
  REGISTROS+=("$(printf '%s\tIN\t%s\t%s' "$NOME" "$TIPO" "$VALOR")")
  TESTES_NOME+=("$NOME"); TESTES_TIPO+=("$TIPO")
  info "Adicionado: $NOME $TIPO $VALOR"
done

TEMPLATE_PADRAO='https://www.free-css.com/assets/files/free-css-templates/download/page296/oxygen.zip'
read -r -p 'URL do template ZIP/TAR.GZ (ENTER = padrao): ' TEMPLATE_URL
TEMPLATE_URL=${TEMPLATE_URL:-$TEMPLATE_PADRAO}
[[ "$TEMPLATE_URL" == https://* || "$TEMPLATE_URL" == http://* ]] || falha 'A URL do template deve iniciar com http:// ou https://.'
printf '\nRESUMO: dominio=%s | IP=%s | registros extras=%s\nTemplate: %s\n' "$DOMINIO" "$IP_SERVIDOR" "${#REGISTROS[@]}" "$TEMPLATE_URL"
pergunta_sim 'Confirmar instalacao?' || { echo 'Cancelado.'; exit 0; }

info '2/7 - Instalando pacotes'
dnf install -y bind bind-utils httpd curl wget unzip tar policycoreutils firewalld

info '3/7 - Preparando zona DNS'
ZONA="/var/named/db.${DOMINIO}"
# Faz backup antes de modificar arquivos de configuracao.
cp -a /etc/named.conf "/etc/named.conf.bak.gs.$(date +%Y%m%d%H%M%S)"
if [[ -e "$ZONA" ]]; then cp -a "$ZONA" "${ZONA}.bak.gs.$(date +%Y%m%d%H%M%S)"; fi
SERIAL=$(date +%Y%m%d%H)
{
  printf '$TTL 3600\n'
  printf '@ IN SOA ns1.%s. admin.%s. (\n' "$DOMINIO" "$DOMINIO"
  printf '  %s 3600 900 604800 3600 )\n' "$SERIAL"
  printf '@ IN NS ns1.%s.\n' "$DOMINIO"
  printf 'ns1 IN A %s\n' "$IP_SERVIDOR"
  printf '@ IN A %s\n' "$IP_SERVIDOR"
  for linha in "${REGISTROS[@]}"; do printf '%s\n' "$linha"; done
} > "$ZONA"
chown root:named "$ZONA"
chmod 640 "$ZONA"
restorecon "$ZONA" || aviso 'Nao foi possivel ajustar o contexto SELinux da zona.'

# Configura escuta e consultas de rede no named.conf padrao do AlmaLinux.
# Evita duplicar a declaracao da zona em execucoes posteriores.
if ! grep -Eq '^[[:space:]]*zone[[:space:]]+"'"$DOMINIO"'"' /etc/named.conf; then
  cat >> /etc/named.conf <<EOF

// Zona criada automaticamente pela Global Solution
zone "$DOMINIO" IN {
    type master;
    file "$ZONA";
    allow-update { none; };
};
EOF
else
  aviso 'Zona ja declarada no named.conf; reutilizando a declaracao existente.'
fi
# Altera apenas as diretivas do arquivo padrao; se estiver personalizado, avisa.
sed -i -E 's/listen-on port 53[[:space:]]*\{[[:space:]]*127\.0\.0\.1;[[:space:]]*\};/listen-on port 53 { any; };/' /etc/named.conf
sed -i -E 's/allow-query[[:space:]]*\{[[:space:]]*localhost;[[:space:]]*\};/allow-query { any; };/' /etc/named.conf
named-checkconf || falha 'Configuracao BIND invalida.'
named-checkzone "$DOMINIO" "$ZONA" || falha 'Zona DNS invalida.'
systemctl enable --now named
systemctl restart named
systemctl is-active --quiet named || falha 'named nao iniciou.'

info '4/7 - Baixando e verificando template HTML'
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:-}"' EXIT
ARQ="$TMP/template"
mkdir -p "$TMP/site"
curl -fL --retry 2 --connect-timeout 15 --max-time 120 -o "$ARQ" "$TEMPLATE_URL" || falha 'Falha no download do template. Informe outra URL valida.'
case "${TEMPLATE_URL%%\?*}" in
  *.zip) unzip -q "$ARQ" -d "$TMP/site" || falha 'ZIP invalido.' ;;
  *.tar.gz|*.tgz) tar -xzf "$ARQ" -C "$TMP/site" || falha 'TAR.GZ invalido.' ;;
  *) unzip -q "$ARQ" -d "$TMP/site" 2>/dev/null || tar -xzf "$ARQ" -C "$TMP/site" || falha 'Arquivo nao e ZIP nem TAR.GZ.' ;;
esac
INDEX=$(find "$TMP/site" -type f -iname index.html -print -quit)
[[ -n "$INDEX" ]] || falha 'Template sem index.html; site anterior preservado.'
ORIGEM=$(dirname "$INDEX")

info '5/7 - Publicando site no Apache'
mkdir -p /var/www/html
# Mantem copia do site anterior (se existir) antes de substitui-lo.
BACKUP="/var/www/html.bak.gs.$(date +%Y%m%d%H%M%S)"
cp -a /var/www/html "$BACKUP"
find /var/www/html -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a "$ORIGEM"/. /var/www/html/
chown -R apache:apache /var/www/html
chmod -R a+rX /var/www/html
restorecon -RF /var/www/html || aviso 'Falha no restorecon do site.'
systemctl enable --now httpd
systemctl restart httpd
systemctl is-active --quiet httpd || falha 'httpd nao iniciou.'

info '6/7 - Ajustando firewall'
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=dns
  firewall-cmd --permanent --add-service=http
  firewall-cmd --reload
else
  aviso 'firewalld inativo: nenhuma regra adicionada.'
fi

info '7/7 - Testes finais'
dig @127.0.0.1 "$DOMINIO" A +short
dig @127.0.0.1 "$DOMINIO" NS +short
for i in "${!TESTES_NOME[@]}"; do
  N=${TESTES_NOME[$i]}; T=${TESTES_TIPO[$i]}
  [[ "$N" == @ ]] && FQDN="$DOMINIO" || FQDN="$N.$DOMINIO"
  printf '[TESTE DNS] %s %s: ' "$FQDN" "$T"
  dig @127.0.0.1 "$FQDN" "$T" +short
done
HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $DOMINIO" http://127.0.0.1/) || falha 'Falha na conexao HTTP local.'
[[ "$HTTP" == 200 ]] || falha "Apache respondeu HTTP $HTTP (esperado 200)."

# ============================================================================
# ETAPA 8 - TRES TAREFAS EXTRAS DA GLOBAL SOLUTION (preencher no dia da prova)
# Tarefa 1:
# Tarefa 2:
# Tarefa 3:
# ============================================================================
printf '\n[OK] Configuracao concluida.\nDominio: %s\nIP: %s\nSite: http://%s\nLog: %s\n' "$DOMINIO" "$IP_SERVIDOR" "$IP_SERVIDOR" "$LOG"
