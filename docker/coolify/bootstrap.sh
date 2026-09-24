#!/bin/sh
set -eu

: "${SUPABASE_DB_URL:?Falta SUPABASE_DB_URL no Coolify}"
: "${NEXT_PUBLIC_SUPABASE_URL:?Falta NEXT_PUBLIC_SUPABASE_URL no Coolify}"
: "${SUPABASE_SERVICE_ROLE_KEY:?Falta SUPABASE_SERVICE_ROLE_KEY no Coolify}"
: "${OWNER_EMAIL:?Falta OWNER_EMAIL no Coolify}"
: "${OWNER_PASSWORD:?Falta OWNER_PASSWORD no Coolify}"
if [ "${#OWNER_PASSWORD}" -lt 8 ]; then
  echo "OWNER_PASSWORD precisa ter pelo menos 8 caracteres." >&2
  exit 1
fi

echo "Conectando ao Supabase e preparando o banco..."
psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -q -c \
  'create extension if not exists vector with schema public;
   create extension if not exists citext with schema public;
   create extension if not exists pg_trgm with schema public;'

schema_exists="$(psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -Atq -c \
  "select 1 from information_schema.tables where table_schema='public' and table_name='organizations' limit 1")"

if [ "$schema_exists" = 1 ]; then
  # O baseline do projeto é re-aplicado em modo update pelo instalador oficial.
  # Ele emite erros inofensivos para objetos antigos; erros diferentes falham.
  echo "Banco existente: aplicando alterações da release..."
  rc=0
  psql "$SUPABASE_DB_URL" -X -q -f /opt/deskcomm/baseline.sql \
    > /tmp/baseline.log 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    tail -20 /tmp/baseline.log >&2
    echo "A aplicação do baseline não chegou ao fim (psql: $rc)." >&2
    exit 1
  fi
  if grep -iE 'ERROR|FATAL' /tmp/baseline.log \
      | grep -viE 'already exists|multiple primary keys|multiple default values|is already a member|already a partition' \
      > /tmp/baseline-errors.log; then
    head -20 /tmp/baseline-errors.log >&2
    echo "O baseline encontrou erros inesperados; o aplicativo não será iniciado." >&2
    exit 1
  fi
else
  echo "Banco novo: instalando o baseline completo..."
  if ! psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -q -f /opt/deskcomm/baseline.sql \
      > /tmp/baseline.log 2>&1; then
    tail -20 /tmp/baseline.log >&2
    echo "O baseline falhou. O aplicativo não será iniciado com o banco incompleto." >&2
    exit 1
  fi
fi

tables="$(psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 -Atq -c \
  "select count(*) from information_schema.tables where table_schema='public'")"
if [ "$tables" -lt 30 ]; then
  echo "O banco tem apenas $tables tabelas public; esperado: pelo menos 30." >&2
  exit 1
fi

echo "Criando o primeiro usuário no Supabase Auth, se necessário..."
auth_payload="$(jq -n \
  --arg email "$OWNER_EMAIL" \
  --arg password "$OWNER_PASSWORD" \
  --arg locale "${APP_LOCALE:-pt-BR}" \
  '{email:$email,password:$password,email_confirm:true,user_metadata:{locale:$locale}}')"
auth_status="$(curl -sS -o /tmp/auth-response.json -w '%{http_code}' \
  -X POST "${NEXT_PUBLIC_SUPABASE_URL%/}/auth/v1/admin/users" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H 'Content-Type: application/json' \
  -d "$auth_payload")"
case "$auth_status" in
  200|201|422) : ;;
  *)
    echo "O Supabase Auth recusou a criação do usuário (HTTP $auth_status)." >&2
    jq -r '.msg // .message // .error // empty' /tmp/auth-response.json >&2 || true
    exit 1
    ;;
esac

# Passamos entradas de usuário como parâmetros do psql; o SQL não concatena
# e-mail ou nome em comandos. A operação é idempotente em cada redeploy.
psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1 \
  -v owner_email="$OWNER_EMAIL" \
  -v org_name="${OWNER_ORG_NAME:-Minha Empresa}" \
  -v app_locale="${APP_LOCALE:-pt-BR}" \
  -v ai_provider="${AI_PROVIDER:-anthropic}" <<'SQL'
select set_config('deskcomm.owner_email', :'owner_email', false);
select set_config('deskcomm.org_name', :'org_name', false);
select set_config('deskcomm.app_locale', :'app_locale', false);
select set_config('deskcomm.ai_provider', :'ai_provider', false);

do $$
declare
  v_uid uuid;
  v_org uuid;
  v_new_org boolean := false;
  v_email text := current_setting('deskcomm.owner_email');
  v_name text := current_setting('deskcomm.org_name');
  v_locale text := current_setting('deskcomm.app_locale');
  v_provider text := current_setting('deskcomm.ai_provider');
begin
  select id into v_uid from auth.users where lower(email) = lower(v_email) limit 1;
  if v_uid is null then
    raise exception 'O usuário dono não foi encontrado no Supabase Auth';
  end if;

  select id into v_org from public.organizations where slug = 'minha-empresa';
  if v_org is null then
    insert into public.organizations (slug, display_name, legal_name, locale, created_by)
    values ('minha-empresa', v_name, v_name, v_locale, v_uid)
    returning id into v_org;
    v_new_org := true;
  end if;

  if v_new_org and v_provider in ('openrouter', 'openai', 'google') then
    update public.organizations
       set settings = jsonb_set(coalesce(settings, '{}'::jsonb),
                                '{llm,provider}', to_jsonb(v_provider), true)
     where id = v_org;
  end if;

  insert into public.user_organizations (user_id, organization_id, role, accepted_at)
  values (v_uid, v_org, 'admin', now())
  on conflict (user_id, organization_id)
  do update set role = 'admin', revoked_at = null;

  if not exists (
    select 1 from public.platform_admins
     where user_id = v_uid and revoked_at is null
  ) then
    insert into public.platform_admins (user_id, granted_by, scope, mfa_required, reason)
    values (v_uid, v_uid, 'full', false, 'Bootstrap inicial pelo Coolify');
  end if;
end $$;
SQL

echo "Supabase preparado: $tables tabelas e administrador inicial configurado."
