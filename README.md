# herd-db

Gerenciador de bancos nativo para macOS — PostgreSQL agora, SQL Server na fase 6.
Interface em português, SwiftUI + AppKit, sem Electron.

![Visão geral do Herd com uma conexão PostgreSQL, editor SQL e grid de resultados](docs/screenshots/visao-geral.png)

<details>
<summary>Mais capturas do aplicativo</summary>

### Editor e resultados

![Editor SQL e grid com dados fictícios](docs/screenshots/editor-consulta.png)

### Nova conexão

![Formulário nativo para configurar uma conexão PostgreSQL](docs/screenshots/conexoes.png)

</details>

**Estado:** fases 1, 2, 3, 4, 5 e 7 concluídas; fase 6 em standby; fase 8 em polimento final.

## Roadmap

| Fase | Escopo                                             | Status             |
| ---- | -------------------------------------------------- | ------------------ |
| 1    | Esqueleto, driver PostgreSQL, conexões e árvore    | ✅ Concluída       |
| 2    | Editor SQL, execução, cancelamento e histórico     | ✅ Concluída       |
| 3    | Autocomplete, snippets e scripts SQL               | ✅ Concluída       |
| 4    | Grid de dados, ações do editor SQL e menus nativos | ✅ Concluída       |
| 5    | Structure/DDL                                      | ✅ Concluída       |
| 6    | FreeTDS + SQL Server                               | ⏸️ Standby         |
| 7    | Backup/restore, novo banco e geração de scripts    | ✅ Concluída       |
| 8    | Polimento, acessibilidade e empacotamento          | 🚧 Polimento final |

## Plano detalhado por fases

### Fase 1 — Esqueleto, driver PostgreSQL e árvore ✅

- [x] Pacote SwiftPM com `HerdCore` (sem UI), `HerdDB` (app) e testes
- [x] Janela nativa com `NavigationSplitView`, sidebar estilo pgAdmin e abas de consulta
- [x] Tema claro/escuro automático e componentes 100% do sistema
- [x] Protocolo `DatabaseDriver` async + `SQLDialect` (quoting, `LIMIT`/`TOP`)
- [x] `PostgresDriver` com `postgres-nio` e pool por conexão
- [x] Descoberta de bancos, schemas, tabelas, views, colunas, PKs e FKs
- [x] Árvore conexão → banco → schema → tabela/view → coluna, com carga sob demanda
- [x] Filtro de objetos, seleção e menu de contexto nativo por tipo de nó
- [x] Gerenciador de conexões: JSON em Application Support, senha no Chaveiro, teste de conexão

### Fase 2 — Aba de consulta ✅

- [x] Editor SQL em `NSTextView`/TextKit 1 com placeholder de atalho
- [x] Realce de sintaxe próprio (keywords, strings, números, comentários e parâmetros)
- [x] Números de linha, indentação automática, Tab em 4 espaços, sem smart quotes/spell check
- [x] Separação de scripts em comandos e ranges (`SQLStatementSplitter`)
- [x] Execução sequencial de vários comandos; erro indica "Comando X de Y"
- [x] `⌘↵` executa script ou seleção; `⌥⌘↵` executa seleção ou comando sob o cursor
- [x] `⇧⌘↵` executa o script inteiro ignorando a seleção
- [x] Cancelamento real via `pg_cancel_backend` em conexão reservada do pool
- [x] Resultados com todos os conjuntos retornados, tempo, contagem de linhas e erros
- [x] Abas com banco, estado de execução e menu de contexto (fechar/copiar SQL)
- [x] Histórico por conexão/banco no inspetor: horário, duração, linhas, erro, reuso e limpeza
- [x] Testes de splitter (21), tokenizer (11), histórico (7), dialeto (6), conexões (2)
      e integração Postgres (7)

### Fase 3 — Autocomplete, snippets e scripts SQL ✅

- [x] Parser leve de contexto (`FROM`/`JOIN`, `alias.`, `schema.`)
- [x] Popup de sugestões com schemas, tabelas, colunas e palavras-chave SQL, filtrável e navegável por teclado
- [x] Snippets `sel`, `ins`, `upd`, `del`, `selt`
- [x] Menu "Scripts SQL" no nó da tabela: SELECT, SELECT 10 linhas, INSERT, UPDATE, DELETE e CREATE (DDL)
- [x] Consulta pronta aberta em nova aba com o SQL preenchido
- [x] Catálogo por banco em três consultas, cacheado por conexão/banco e invalidado ao atualizar a árvore
- [x] Popup nativo não ativante: `⌥Space`, `⌃Space` ou F5 abre, setas navegam, Return/Tab inserem, Esc fecha
- [x] Validar o popup visualmente em claro/escuro, perto das bordas da janela e com o editor redimensionado
- [x] 20 testes de autocomplete (contexto, alias, schema, filtro, ordenação e snippets);
      catálogo coberto no teste de integração do Postgres (74 testes no total)

### Fase 4 — Grid de dados, editor SQL e menus nativos ✅

- [x] Largura das colunas ajustável arrastando a borda do cabeçalho
- [x] Paginação local de 100 linhas e filtro local sobre o resultado carregado
- [x] Seleção de linhas (individual, `⌘` e intervalo em lote com `Shift`) e cópia em TSV, com opção de incluir cabeçalhos e exportar CSV
- [x] Alternância entre dados e mensagens da execução
- [x] Adicionar nova linha inline no final do grid com preenchimento célula a célula (`Tab` / `⇧Tab` / `Return`)
- [x] Grid virtualizado (`LazyVStack`) com linhas alternadas e cabeçalho nativo (com indicadores de PK e FK)
- [x] Paginação de 500 linhas com navegação ao abrir uma tabela pela árvore
- [x] Ordenação por coluna e filtro de texto executados no servidor ao navegar pela tabela
- [x] Edição inline com duplo clique na célula e destaque das células alteradas, inseridas e marcadas para remoção
- [x] Geração de `INSERT`, `UPDATE ... WHERE <pk>` e `DELETE ... WHERE <pk>` e sheet "Revisar alterações SQL"
- [x] Execução em transação (`BEGIN ... COMMIT`), salvar e descartar alterações
- [x] FK clicável para abrir a linha referenciada em nova aba
- [x] Atalhos e ações rápidas de edição e busca no editor e no grid

#### Ações rápidas do script

- [x] Adicionar ao editor SQL um menu de contexto com **Buscar**, **Substituir** e **Ir para linha/coluna**, com foco no campo correto, navegação entre ocorrências e seleção do destino; os mesmos comandos devem funcionar pelo teclado
- [x] Adicionar **Indentar seleção**, **Remover indentação**, **Comentar/descomentar**, **Alternar maiúsculas/minúsculas da seleção**, **Limpar consulta** e **Formatar SQL** ao menu de contexto; operações de edição devem integrar o desfazer/refazer do `NSTextView`
- [x] Definir a formatação SQL para seleção ou documento inteiro, preservando conteúdo de strings e comentários, respeitando o dialeto da conexão e mantendo seleção/cursor em posição útil após a alteração
- [x] Habilitar ações conforme o estado: busca, navegação e formatação exigem script ativo; ações sobre seleção exigem seleção; limpar consulta exige texto; comandos de edição ficam indisponíveis quando o editor não puder ser alterado

#### Barra de menus do macOS

- [x] Reorganizar **Arquivo** com **Novo ▸** (Script, Conexão e objetos do banco aplicáveis ao contexto), **Abrir arquivo SQL…**, ações de salvar e fechamento de aba/janela; abrir `.sql` em nova aba vinculada à conexão/banco escolhido, com tratamento de codificação e alterações não salvas
- [x] Em **Novo ▸**, oferecer no contexto de banco/schema/tabela os modelos de criação disponíveis, como Tabela, Schema, Coluna, Índice, Regra, Trigger e Política RLS; abrir o DDL em um script para revisão, respeitar o dialeto e ocultar ou desabilitar itens sem contexto ou suporte, sem executar DDL automaticamente
- [x] Integrar **Editar** às ações rápidas do SQL quando houver script ativo, além dos comandos nativos Desfazer/Refazer, Recortar, Copiar, Colar e Selecionar Tudo; estado habilitado e atalhos devem acompanhar o foco real do editor para não interferir nos campos de busca e no grid
- [x] Remover **Visualizar > Mostrar Barra de Abas** do menu de sistema, pois a opção conflita com a barra de abas própria do app; manter a navegação entre abas funcionando e conferir que o item não reaparece ao trocar de janela/aba

### Fase 5 — Structure/DDL ✅

- [x] Aba/Sheet Structure (`TableStructureSheet`) com colunas, índices e constraints/chaves estrangeiras
- [x] DDL gerado (`CREATE TABLE`, índices, constraints)
- [x] Alterações via preview e execução de `ALTER TABLE` + wizards nativos (`CreateTableSheet`, `CreateSchemaSheet`, `CreateTableSubObjectSheet`, `DropObjectSheet`)
- [x] Atalho `⌘I`

### Fase 6 — SQL Server ⏸️ (Standby)

- [ ] FreeTDS (dblib) compilado como xcframework e embutido no `.app`
- [ ] `MSSQLDriver` async com pool e cancelamento
- [ ] Dialeto `[x]`/`TOP` e catálogos do SQL Server
- [ ] Paridade: árvore, abas, execução, resultados e histórico
- [ ] Testes contra SQL Server em Docker

### Fase 7 — Backup, restore, novo banco e scripts ✅

- [x] Backup/restore PostgreSQL com `pg_dump`/`pg_restore`/`psql` (`.dump` e `.sql`), progresso e log na aba **Processos**
- [ ] Backup/restore SQL Server via `BACKUP DATABASE`/`RESTORE DATABASE` (em standby junto com a Fase 6)
- [x] Novo banco pela interface (`CreateDatabaseSheet` / `⌥⌘D`)
- [x] Gerar script CREATE/INSERT/UPDATE/DELETE/SELECT pelo menu da tabela
- [x] Copiar nome do objeto (`⌥⌘C`) e atualizar nó (`⌘R`)

### Fase 8 — Polimento e empacotamento 🚧

- [x] Ícone do app claro/escuro e ícones IconMCP na interface (com alternância outline/filled quando ativo)
- [x] Barra de título compacta e janela com visual nativo (liquid glass)
- [x] Menus de contexto 100% nativos, sem menus desenhados à mão
- [x] `scripts/build-app.sh` com bundle, ícones e assinatura ad-hoc
- [x] Estados vazios, de erro e de carregamento definitivos em todas as telas
- [x] Atalhos completos (`⌘B`, `⌥⌘B`, `⌘J`, `⌘E`, `⌘I`, `⌘F`, `⇧⌘F`, `⌥⌘F`, `⌃G`, `⇧⌥F`, `⌘/`, `⌘1…9`, `⌥⌘N`, `⌥⌘S`, `⌥⌘D`, `⇧⌘B/R`)
- [ ] Revisão de acessibilidade
- [ ] Notarização e distribuição

## Limitações atuais

- SQL Server permanece em standby (Fase 6) e aparece na lista de tipos como "em breve".
- Resultados de scripts livres são limitados a 20 000 linhas em memória com paginação local de 100 linhas; tabelas abertas pela árvore usam paginação de 500 linhas, ordenação, filtro no servidor e edição transacional inline (`INSERT` / `UPDATE` / `DELETE`).
- O autocomplete sugere objetos do banco (em todos os schemas), colunas, palavras-chave SQL e snippets; ainda não resolve colunas de subconsultas ou CTEs complexas.
- Histórico limitado a 200 entradas por conexão/banco.

## Atalhos

| Atalho                                | Ação                                                                                 |
| ------------------------------------- | ------------------------------------------------------------------------------------ |
| `⌘↵`                                  | Executar o script ou a seleção                                                       |
| `⇧⌘↵`                                 | Executar o script inteiro, ignorando a seleção                                       |
| `⌥⌘↵`                                 | Executar a seleção ou o comando sob o cursor                                         |
| `⌘.`                                  | Cancelar a execução                                                                  |
| `⌘T` / `⌥⌘T`                          | Novo script / Fechar outras abas                                                     |
| `⌘W` / `⇧⌘W`                          | Fechar aba (ou janela) / Fechar todas as abas                                        |
| `⌘1` a `⌘9`                           | Alternar entre abas abertas (`⌘9` vai para a última aba)                             |
| `⇧⌘N`                                 | Nova conexão                                                                         |
| `⌘O`                                  | Abrir arquivo SQL                                                                    |
| `⌘S` / `⇧⌘S`                          | Salvar / salvar como arquivo SQL                                                     |
| `⌘F`                                  | Buscar no editor SQL (ou filtrar objetos na sidebar quando o editor não está focado) |
| `⌥⌘F`                                 | Substituir no editor SQL                                                             |
| `⇧⌘F`                                 | Filtrar objetos na barra lateral                                                     |
| `⌃G`                                  | Ir para linha/coluna no editor SQL                                                   |
| `⌘/`                                  | Comentar ou descomentar linhas                                                       |
| `⇧⌥F`                                 | Formatar SQL                                                                         |
| `⌘]` / `⌘[` (ou `Tab` / `⇧Tab`)       | Indentar / remover indentação da seleção                                             |
| `⌃⇧U`                                 | Alternar maiúsculas/minúsculas da seleção                                            |
| `⌥Space`, `⌃Space` ou `F5`            | Abrir o autocomplete no cursor                                                       |
| `↑` `↓` / `Return` ou `Tab` / `Esc`   | Navegar / inserir / fechar o autocomplete                                            |
| `⌘B`                                  | Alternar barra lateral (padrão VS Code)                                              |
| `⌥⌘B`                                 | Alternar inspetor de histórico (padrão VS Code)                                      |
| `⌘J`                                  | Alternar painel inferior de resultados (padrão VS Code)                              |
| `⌘I`                                  | Estrutura / DDL da tabela selecionada                                                |
| `⌘R`                                  | Atualizar árvore / nó selecionado                                                    |
| `⌥⌘D` / `⌥⌘N` / `⌥⌘S`                 | Criar Banco de dados / Tabela / Schema (wizards nativos)                             |
| `⌥⌘K` / `⌥⌘I` / `⌥⌘U` / `⌥⌘G` / `⌥⌘Y` | Criar Coluna / Índice / Regra / Trigger / Política RLS                               |
| `⌘⌫` / `⌥⌘⌫`                          | Excluir objeto / Excluir em cascata (com confirmação digitando o nome)               |
| `⇧⌘B` / `⇧⌘R`                         | Backup / Restore do banco ou tabela                                                  |
| `⇧⌘I` / `⇧⌘E`                         | Importar / Exportar CSV da tabela                                                    |
| `⌥⌘P`                                 | Ver aba de Processos                                                                 |
| `⌥⇧⌘1` a `⌥⇧⌘6`                       | Scripts SQL: SELECT, SELECT 10, INSERT, UPDATE, DELETE, CREATE (DDL)                 |

## Ações de objetos e processos

O menu de contexto oferece wizards nativos do macOS para criação de bancos, schemas,
tabelas e sub-objetos (com preview SQL em tempo real e execução direta), inspeção de
estrutura/DDL (`⌘I`) e exclusão segura (`DROP`) com confirmação digitando o nome do objeto.
Backups usam `pg_dump` (formato customizado `.dump` ou texto `.sql`); restauração usa
`pg_restore --clean --if-exists` para `.dump` ou `psql --file` para `.sql`. Tabelas podem
importar e exportar CSV via `psql`. A aba **Processos** mostra cada operação, saída completa
(stdout + stderr), duração e botão de cancelamento. Essas ferramentas são detectadas
automaticamente em `/opt/homebrew/opt/postgresql@{18,17,16}/bin`, `/opt/homebrew/bin`,
`/usr/local/bin` ou `Postgres.app`.
