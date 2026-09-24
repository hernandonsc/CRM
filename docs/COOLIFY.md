# DeskcommCRM no Coolify (Supabase na nuvem)

Este arquivo acompanha a ramificação `coolify-deploy` do fork. Ela parte da
release `v1.47.0` do DeskcommCRM. O Coolify gerencia os serviços, o domínio,
o HTTPS e os logs. O banco, Auth, Realtime e Storage ficam no Supabase Cloud.

## O que preparar

1. Um subdomínio, por exemplo `crm.seudominio.com.br`, com registro **A**
   apontando para o IP da VPS do Coolify.
2. Um projeto **novo e vazio** no Supabase Cloud. Em **Connect**, copie a URI
   **Session pooler** do banco (porta 5432) e coloque a senha real do banco no
   lugar de `[YOUR-PASSWORD]`. Em **Settings → API Keys**, copie a URL do projeto,
   a chave `anon` e a chave `service_role`. Esta release usa a chave
   `service_role` na API administrativa de Auth. Nunca a publique no GitHub.
3. Um e-mail e uma senha forte para o primeiro administrador.

## Criar o aplicativo no Coolify

1. Abra um projeto do Coolify e clique em **+ New → Public Repository**.
2. Use `https://github.com/hernandonsc/CRM` como repositório e a branch
   `coolify-deploy`.
3. Em **Configuration → General**, escolha **Docker Compose** como Build Pack.
   Base Directory: `/`. Docker Compose Location: `docker-compose.coolify.yml`.
   Salve para o Coolify ler os serviços.
4. Em **Environment Variables**, preencha os campos abaixo. O Coolify gera as
   variáveis `SERVICE_HEX_*` e `SERVICE_REALBASE64_*` automaticamente; mantenha
   os valores gerados. Marque senhas e chaves como secretas no painel.

   | Variável | Valor |
   | --- | --- |
   | `APP_URL` | `https://crm.seudominio.com.br` (seu domínio real, sem barra final) |
   | `NEXT_PUBLIC_SUPABASE_URL` | URL do projeto Supabase |
   | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Chave `anon` do Supabase |
   | `SUPABASE_SERVICE_ROLE_KEY` | Chave `service_role` do Supabase |
   | `SUPABASE_DB_URL` | URI **Session pooler**, com a senha do banco |
   | `OWNER_EMAIL` | E-mail do primeiro administrador |
   | `OWNER_PASSWORD` | Senha do primeiro administrador (mínimo 8 caracteres) |

5. No serviço **gateway**, em **Domains**, coloque
   `https://crm.seudominio.com.br:8080`. O `:8080` indica a porta **interna**
   do contêiner. Na internet, o endereço continua sendo
   `https://crm.seudominio.com.br`, sem porta. Deixe **app**, **waha** e todos
   os demais serviços sem domínio público. Mantenha **Raw Compose Deployment**
   desligado.
6. Clique em **Deploy**. O serviço `bootstrap` aplica o schema no Supabase e
   cria o administrador. Ele termina com estado **exited (0)**; isso é normal
   para uma tarefa única. Espere `app`, `worker`, `waha`, `redis`, `srh`,
   `scheduler` e `gateway` ficarem saudáveis. Se falhar, abra o log do serviço
   que falhou. Não copie chaves ou senhas dos logs para conversas públicas.

## Ajuste final no Supabase

Em **Authentication → URL Configuration**:

- **Site URL:** `https://crm.seudominio.com.br`
- **Redirect URLs:** adicione `https://crm.seudominio.com.br/auth/confirm`

Depois abra o domínio do CRM, entre com `OWNER_EMAIL` e `OWNER_PASSWORD`,
e conecte o WhatsApp por QR code no onboarding. O serviço `gateway` impede
acesso público ao webhook global do WAHA, mas o WAHA alcança o app pela rede
privada do Compose.

## Atualizações e cuidados

- As três imagens do Deskcomm usam a mesma versão (`DESKCOMM_VERSION`, padrão
  `1.47.0`). A branch `coolify-deploy` deve acompanhar a **mesma release** para
  que o `baseline.sql` aplicado no deploy corresponda ao código. Atualize a
  branch e a variável juntas; depois use **Deploy** no Coolify. Não misture
  `latest` ou `stable` com um baseline de outra versão.
- `bootstrap` reaplica o baseline ao iniciar; ele preserva a senha de um
  administrador já existente. O processo para se houver erro inesperado de SQL.
- **Faça backup do Supabase antes de atualizar.** O Coolify cuida dos volumes
  do WAHA na VPS, mas o banco está no Supabase Cloud e precisa de um plano de
  backup próprio.
- O WAHA usa a API não oficial por QR code. O volume `waha-data` guarda a
  sessão; removê-lo exige parear o número novamente.

Documentação do Coolify: https://coolify.io/docs/applications/builds/docker-compose
