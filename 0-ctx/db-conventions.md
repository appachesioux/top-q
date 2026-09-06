# Convenções de banco de dados

Aplicáveis aos projetos PostgreSQL controlados pelo proprietário. Decisões específicas do domínio permanecem no contexto do projeto.

## Tipos e valores zero

- Favoreça tipos simples e `NOT NULL`, alinhados aos valores zero do Go.
- Strings podem usar `''`, números podem usar `0` e booleanos podem usar `false` quando esses valores representarem corretamente a ausência ou o estado inicial.
- Um valor zero válido não implica `DEFAULT`. Use `DEFAULT` somente quando omitir o campo realmente deva produzir aquele valor.
- Campos obrigatórios sem padrão permanecem `NOT NULL`, sem `DEFAULT`.
- Valores monetários usam `numeric(18,2)`; quantidades usam `numeric(18,4)`.

## IDs e nomes

- PK: `<nome_completo_da_tabela>_id`, com `varchar(100)`, `NOT NULL` e valor globalmente único e não vazio.
- Por padrão, FK usa exatamente o nome e o tipo da PK referenciada.
- PKs e FKs têm uma única coluna; nunca use PK ou FK composta.
- Não forme IDs pela composição de tenant, código ou outros campos.
- Um código global, obrigatório e estável pode ser usado diretamente como ID, sem coluna `codigo` duplicada.
- Código mutável ou único apenas no tenant usa coluna própria e ID global independente.
- Quando houver mais de uma FK para a mesma tabela, use nomes que expressem o papel da relação.

## Tenant e relacionamentos

- Toda tabela com tenant possui `sys_tenant_id` com FK para `sys_tenant(sys_tenant_id)`.
- A aplicação garante que registros relacionados pertencem ao mesmo tenant e filtra consultas e alterações pelo ID e pelo tenant.
- Unicidades de negócio incluem o tenant: `UNIQUE (sys_tenant_id, codigo)`.
- `UNIQUE` pode envolver várias colunas; a proibição de chaves compostas aplica-se somente a PKs e FKs.
- Tabela de associação N:N possui ID próprio e uma constraint `UNIQUE` sobre as FKs que não podem se repetir.
- FKs usam `ON UPDATE CASCADE` e `ON DELETE RESTRICT`.
- Toda FK possui índice, salvo quando um índice existente já a atende.

## Índices e constraints

- Use nomes explícitos com os sufixos `_pkey`, `_fkey`, `_ukey`, `_idx` e `_chk`.
- Não duplique índices já fornecidos por PK ou `UNIQUE`.
- Campos usados regularmente para localizar, filtrar ou ordenar registros possuem índice. Isso normalmente inclui código, nome e datas de negócio.
- Em tabelas com tenant, índices de negócio começam por `sys_tenant_id` quando as consultas também são limitadas pelo tenant.
- Enumerações são armazenadas pelo nome e validadas por `CHECK`; não use enum nativo nem posição numérica.

## Datas e auditoria

- Use `date` para data civil e `timestamptz` para um instante.
- Banco e aplicação trabalham internamente em UTC; conversão para horário local ocorre na entrada e apresentação.
- Envie datas como valores tipados, não como strings. Quando formatar, use relógio de 24 horas.
- Intervalos usam início inclusivo e fim exclusivo: `valor >= inicio AND valor < fim`.
- Todas as tabelas possuem `created_by`, `modified_by`, `created_at` e `modified_at`.
- `created_by` e `modified_by` são `varchar(100) NOT NULL` com FKs para `sys_user(sys_user_id)`.
- `created_at` e `modified_at` são `timestamptz NOT NULL DEFAULT current_timestamp`.
- Em toda atualização de dados, a aplicação define `modified_by` e `modified_at = current_timestamp` na mesma operação. Não use trigger para auditoria.

## Migrations

- Projetos Go usam Goose; projetos Java usam Flyway.
- Migration publicada ou anterior à alteração atual é imutável. Faça qualquer correção em uma nova migration.
- Migration criada no trabalho atual, usada somente no processo local e não publicada pode ser editada ou consolidada, mesmo após aplicação em banco local transitório.
- Nunca execute DDL, DML ou migration sem autorização explícita e nunca opere banco remoto.
