#!/usr/bin/env bash
# Global Solution - AlmaLinux 9 | BIND autoritativo + Apache + template externo
# Executar como root em VM de laboratorio: bash gs_almalinux9_corrigido.sh
# ATENCAO: altera rede, BIND, firewall e conteudo de /var/www/html.
set -Eeuo pipefail
(( EUID == 0 )) || { echo '[ERRO] Execute como root.' >&2; exit 1; }
LOG=/var/log/gs_dns_web.log
exec > >(tee -a "$LOG") 2>&1
TMP=''
cleanup(){ [[ -z "$TMP" ]] || rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'echo "[ERRO] Linha $LINENO; consulte $LOG" >&2' ERR
info(){ printf '\n[INFO] %s\n' "$*"; }
aviso(){ printf '\n[AVISO] %s\n' "$*"; }
falha(){ printf '\n[ERRO] %s\n' "$*" >&2; exit 1; }
confirma(){ local r; read -r -p "$1 [s/N]: " r; [[ "${r,,}" == s || "${r,,}" == sim ]]; }
valida_ipv4(){ local ip=$1 o; [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; local -a a; IFS=. read -r -a a <<< "$ip"; for o in "${a[@]}"; do (( 10#$o <= 255 )) || return 1; done; }
valida_dominio(){ [[ ${#1} -le 253 && "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; }
valida_nome(){ [[ "$1" == @ || "$1" =~ ^[a-zA-Z0-9_-]+(\.[a-zA-Z0-9_-]+)*$ ]]; }
normaliza_alvo(){ local x=${1%.}; [[ "$x" == *.* ]] && printf '%s.\n' "$x" || printf '%s\n' "$x"; }

printf '\n=== GLOBAL SOLUTION | ALMALINUX 9 | DNS + WEB ===\n'
echo 'O script modifica configuracoes de rede, BIND, Apache e firewall.'
confirma 'Deseja continuar?' || exit 0
info '1/8 - Coletando dados e verificando ambiente'
. /etc/os-release
[[ "${ID:-}" == almalinux || " ${ID_LIKE:-} " == *rhel* ]] || falha 'Use AlmaLinux/RHEL.'
for c in dnf nmcli ip awk; do command -v "$c" >/dev/null || falha "Falta comando: $c"; done
IFACE=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
[[ -n "$IFACE" ]] || falha 'Nenhuma interface com rota padrao.'
CONEXAO=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" | head -n1)
[[ -n "$CONEXAO" && "$CONEXAO" != '--' ]] || falha 'Conexao NetworkManager nao encontrada.'
IP_ATUAL=$(ip -4 -o addr show dev "$IFACE" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')
CIDR_ATUAL=$(ip -4 -o addr show dev "$IFACE" scope global | awk 'NR==1 {print $4}')
GATEWAY=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
[[ -n "$IP_ATUAL" && -n "$GATEWAY" ]] || falha 'IP/gateway nao identificados.'
while :; do
  read -r -p 'Dominio DNS (ex.: seuapelido.lab): ' DOMINIO
  DOMINIO=${DOMINIO,,}; DOMINIO=${DOMINIO%.}
  valida_dominio "$DOMINIO" && [[ "$DOMINIO" == *.lab ]] && break
  aviso 'O dominio deve ser valido e terminar em .lab (ex.: sakura.lab).'
done
while :; do
  read -r -p "IP fixo do servidor [$IP_ATUAL]: " IP_SERVIDOR
  IP_SERVIDOR=${IP_SERVIDOR:-$IP_ATUAL}
  valida_ipv4 "$IP_SERVIDOR" && break
  aviso 'IPv4 invalido.'
done
PREFIXO=${CIDR_ATUAL#*/}
info "Rede detectada: $IFACE | IP $IP_ATUAL/$PREFIXO | gateway $GATEWAY"
[[ "$IP_SERVIDOR" == "$IP_ATUAL" ]] || aviso 'IP diferente do atual: confirme que pertence a rede e nao esta em uso.'
REGISTROS=(); TESTES_NOME=(); TESTES_TIPO=()
info 'Registros padrao: NS ns1, A ns1, A @ e A www.'
echo 'Adicionais: A, AAAA, CNAME, MX ou TXT; ENTER encerra.'
while :; do
  read -r -p 'Tipo (ou ENTER): ' TIPO; TIPO=${TIPO^^}
  [[ -n "$TIPO" ]] || break
  case "$TIPO" in A|AAAA|CNAME|MX|TXT) ;; *) aviso 'Tipo nao suportado.'; continue;; esac
  read -r -p 'Nome (ex.: mail, blog, @): ' NOME; NOME=${NOME:-@}
  valida_nome "$NOME" || { aviso 'Nome invalido.'; continue; }
  [[ "$NOME" != www && "$NOME" != ns1 ]] || { aviso 'www e ns1 ja estao reservados.'; continue; }
  case "$TIPO" in
    A) read -r -p 'IPv4: ' VALOR; valida_ipv4 "$VALOR" || { aviso 'IP invalido.'; continue; } ;;
    AAAA) read -r -p 'IPv6: ' VALOR; [[ "$VALOR" == *:* && "$VALOR" =~ ^[0-9a-fA-F:]+$ ]] || { aviso 'IPv6 invalido.'; continue; } ;;
    CNAME) [[ "$NOME" != @ ]] || { aviso 'CNAME nao pode usar @.'; continue; }; read -r -p 'Destino (ex.: www ou outro.dominio): ' VALOR; valida_nome "$VALOR" || { aviso 'Destino invalido.'; continue; }; VALOR=$(normaliza_alvo "$VALOR") ;;
    MX) read -r -p 'Prioridade (ex.: 10): ' PRIO; [[ "$PRIO" =~ ^[0-9]{1,5}$ ]] && (( 10#$PRIO <= 65535 )) || { aviso 'Prioridade invalida.'; continue; }; read -r -p 'Servidor de email: ' ALVO; valida_nome "$ALVO" && [[ "$ALVO" != @ ]] || { aviso 'Destino invalido.'; continue; }; VALOR="$PRIO $(normaliza_alvo "$ALVO")" ;;
    TXT) read -r -p 'Texto (sem aspas): ' VALOR; [[ -n "$VALOR" && ${#VALOR} -le 255 && "$VALOR" != *'"'* && "$VALOR" != *'\\'* ]] || { aviso 'TXT invalido.'; continue; }; VALOR="\"$VALOR\"" ;;
  esac
  REGISTROS+=("$(printf '%s\tIN\t%s\t%s' "$NOME" "$TIPO" "$VALOR")")
  TESTES_NOME+=("$NOME"); TESTES_TIPO+=("$TIPO")
done
# Fonte externa conhecida: projeto open source Start Bootstrap; tenta master e main.
TEMPLATE_PADRAO='https://github.com/StartBootstrap/startbootstrap-landing-page/archive/refs/heads/master.zip'
read -r -p 'URL ZIP/TAR.GZ do template (ENTER = padrao): ' TEMPLATE_URL
TEMPLATE_URL=${TEMPLATE_URL:-$TEMPLATE_PADRAO}
[[ "$TEMPLATE_URL" == https://* ]] || falha 'Use URL HTTPS para o template.'
printf '\nRESUMO: dominio=%s | IP=%s/%s | gateway=%s | interface=%s\nTemplate: %s\n' "$DOMINIO" "$IP_SERVIDOR" "$PREFIXO" "$GATEWAY" "$IFACE" "$TEMPLATE_URL"
confirma 'Confirmar instalacao?' || exit 0

info '2/8 - Instalando pacotes'
dnf install -y bind bind-utils httpd curl unzip tar firewalld policycoreutils
TMP=$(mktemp -d)
mkdir -p "$TMP/site"
info '3/8 - Baixando template antes de alterar o site'
ARQ="$TMP/template"
if ! curl -fLSs --retry 2 --connect-timeout 15 --max-time 120 -o "$ARQ" "$TEMPLATE_URL"; then
  if [[ "$TEMPLATE_URL" == "$TEMPLATE_PADRAO" ]]; then
    aviso 'Tentando branch main do template...'
    TEMPLATE_URL='https://github.com/StartBootstrap/startbootstrap-landing-page/archive/refs/heads/main.zip'
    curl -fLSs --retry 2 --connect-timeout 15 --max-time 120 -o "$ARQ" "$TEMPLATE_URL" || falha 'Falha no download do template externo.'
  else
    falha 'Falha no download do template externo.'
  fi
fi
case "${TEMPLATE_URL%%\?*}" in
  *.zip) unzip -q "$ARQ" -d "$TMP/site" || falha 'ZIP invalido.' ;;
  *.tar.gz|*.tgz) tar -xzf "$ARQ" -C "$TMP/site" || falha 'TAR.GZ invalido.' ;;
  *) falha 'URL deve apontar para ZIP ou TAR.GZ.' ;;
esac
INDEX=$(find "$TMP/site" -type f -iname index.html -print -quit)
[[ -n "$INDEX" ]] || falha 'Template sem index.html.'
ORIGEM=$(dirname "$INDEX")

info '4/8 - Configurando BIND autoritativo e seguranca DNS'
STAMP=$(date +%Y%m%d%H%M%S)
cp -a /etc/named.conf "/etc/named.conf.bak.gs.$STAMP"
ZONA="/var/named/db.${DOMINIO}"
[[ ! -f "$ZONA" ]] || cp -a "$ZONA" "$ZONA.bak.gs.$STAMP"
SERIAL=$(date +%Y%m%d%H)
{
  printf '$TTL 3600\n@ IN SOA ns1.%s. admin.%s. (\n %s 3600 900 604800 3600 )\n' "$DOMINIO" "$DOMINIO" "$SERIAL"
  printf '@ IN NS ns1.%s.\nns1 IN A %s\n@ IN A %s\nwww IN A %s\n' "$DOMINIO" "$IP_SERVIDOR" "$IP_SERVIDOR" "$IP_SERVIDOR"
  for r in "${REGISTROS[@]}"; do printf '%s\n' "$r"; done
} > "$ZONA"
chown root:named "$ZONA"; chmod 640 "$ZONA"
restorecon "$ZONA" || aviso 'Nao foi possivel restaurar contexto SELinux da zona.'
# Ajusta as diretivas do arquivo padrao do AlmaLinux 9.
sed -i -E 's/listen-on port 53[[:space:]]*\{[^}]*\};/listen-on port 53 { any; };/' /etc/named.conf
sed -i -E 's/allow-query[[:space:]]*\{[^}]*\};/allow-query { any; };/' /etc/named.conf
# Evita inserir diretivas duplicadas: inclui seguranca na declaracao da zona.
if grep -Eq "^[[:space:]]*zone[[:space:]]+\"${DOMINIO}\"" /etc/named.conf; then
  falha 'Zona ja declarada em named.conf. Use clone limpo para homologacao/produção.'
fi
cat >> /etc/named.conf <<ZONE

// Global Solution: zona autoritativa sem transferencias
zone "$DOMINIO" IN {
    type master;
    file "$ZONA";
    allow-update { none; };
    allow-transfer { none; };
};
ZONE
# Diretiva global: sem recursao, evitando DNS aberto para terceiros.
sed -i -E 's/^[[:space:]]*recursion[[:space:]]+(yes|no);/        recursion no;/' /etc/named.conf
if ! grep -Eq '^[[:space:]]*recursion[[:space:]]+no;' /etc/named.conf; then
  sed -i '/^[[:space:]]*options[[:space:]]*{/a\        recursion no;' /etc/named.conf
fi
if ! grep -Eq '^[[:space:]]*allow-recursion[[:space:]]*' /etc/named.conf; then
  sed -i '/^[[:space:]]*options[[:space:]]*{/a\        allow-recursion { none; };' /etc/named.conf
fi
named-checkconf || falha 'named.conf invalido.'
named-checkzone "$DOMINIO" "$ZONA" || falha 'Zona DNS invalida.'
systemctl enable --now named
systemctl restart named
systemctl is-active --quiet named || falha 'named inativo.'

info '5/8 - Publicando template e ocultando versao do Apache'
mkdir -p /var/www/html
cp -a /var/www/html "/var/www/html.bak.gs.$STAMP"
find /var/www/html -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a "$ORIGEM"/. /var/www/html/
chown -R apache:apache /var/www/html
chmod -R a+rX /var/www/html
restorecon -RF /var/www/html || aviso 'Nao foi possivel restaurar contexto SELinux do site.'
cat > /etc/httpd/conf.d/gs_security.conf <<'APACHE'
# Global Solution - reduzir informacoes do servidor no HTTP
ServerTokens Prod
ServerSignature Off
APACHE
httpd -t || falha 'Configuracao Apache invalida.'
systemctl enable --now httpd
systemctl restart httpd
systemctl is-active --quiet httpd || falha 'Apache inativo.'

info '6/8 - Configurando firewall e inicializacao automatica'
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=dns
firewall-cmd --permanent --add-service=http
firewall-cmd --reload
systemctl enable named httpd

info '7/8 - Configurando IP fixo (NetworkManager)'
# Configura o perfil, mantendo o IP e gateway detectados; o reboot aplica o perfil.
# DNS de sistema: usa o proprio BIND depois do reboot.
nmcli con mod "$CONEXAO" ipv4.method manual ipv4.addresses "$IP_SERVIDOR/$PREFIXO" ipv4.gateway "$GATEWAY" ipv4.dns "$IP_SERVIDOR" ipv4.ignore-auto-dns yes
info "Perfil $CONEXAO preparado com IP fixo $IP_SERVIDOR/$PREFIXO."

info '8/8 - Validando DNS, HTTP, servicos e seguranca'
[[ "$(dig @127.0.0.1 "$DOMINIO" A +short | head -n1)" == "$IP_SERVIDOR" ]] || falha 'Teste DNS A falhou.'
[[ "$(dig @127.0.0.1 "www.$DOMINIO" A +short | head -n1)" == "$IP_SERVIDOR" ]] || falha 'Teste DNS www falhou.'
for i in "${!TESTES_NOME[@]}"; do
  N=${TESTES_NOME[$i]}; T=${TESTES_TIPO[$i]}
  [[ "$N" == @ ]] && FQDN="$DOMINIO" || FQDN="$N.$DOMINIO"
  info "Teste adicional $FQDN $T: $(dig @127.0.0.1 "$FQDN" "$T" +short)"
done
HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $DOMINIO" http://127.0.0.1/) || falha 'HTTP local falhou.'
[[ "$HTTP" == 200 ]] || falha "Apache respondeu $HTTP, esperado 200."
systemctl is-enabled --quiet named && systemctl is-enabled --quiet httpd || falha 'Servicos nao habilitados.'
[[ "$(nmcli -g ipv4.method con show "$CONEXAO")" == manual ]] || falha 'IP fixo nao salvo.'
info "SUCESSO: DNS $DOMINIO, Apache HTTP 200, IP fixo preparado, firewall e seguranca configurados."
echo "Site: http://www.$DOMINIO | IP: $IP_SERVIDOR | Log: $LOG"
# Reboot SOMENTE depois de todas as validacoes concluirem.
info 'Todas as etapas concluidas. Reinicializacao automatica em 10 segundos (Ctrl+C cancela).'
sleep 10
systemctl reboot
