# herd-db

Gerenciador de bancos nativo para macOS — PostgreSQL agora, SQL Server na fase 6.
Interface em português, SwiftUI + AppKit, sem Electron.

![Visão geral](docs/mockups/visao-geral.png)

## Fase 2 — o que já funciona

- Janela nativa com `NavigationSplitView`, sidebar estilo pgAdmin e abas de consulta.
- Árvore conexão → banco → schema → tabelas/views → colunas, com carregamento sob demanda,
  filtro de objetos e menu de contexto nativo por tipo de nó.
- Driver PostgreSQL (`postgres-nio`) com descoberta de bancos, schemas, tabelas, views,
  colunas, chaves primárias e estrangeiras.
- Gerenciador de conexões: metadados em JSON, senha no Chaveiro do macOS, teste de conexão.
- Editor SQL em `NSTextView` (TextKit 1), com numeração de linhas, realce de sintaxe,
  indentação automática, tabulação em 4 espaços e placeholder de atalho.
- Execução de scripts com vários comandos em sequência; erros indicam qual comando falhou
  ("Comando X de Y") e os resultados exibem o último comando que retornou colunas.
- `⌘↵` executa o script (ou a seleção, se houver); `⌥⌘↵` executa a seleção ou o comando
  sob o cursor; `⌘.` cancela de verdade via `pg_cancel_backend`.
- Aba de consulta com seletor de banco, indicador de execução, botão de cancelar e
  resultados somente leitura com tempo, contagem de linhas e mensagens de erro.
- Histórico de consultas por conexão/banco no inspetor lateral: horário, duração, linhas,
  sucesso/erro, reuso do SQL no editor e limpeza do histórico.
- Light/dark automáticos, ícones e menus 100% do sistema.

Limitações conhecidas desta fase:

- SQL Server aparece na lista de tipos como "em breve" e não conecta.
- Resultados limitados a 20 000 linhas em memória; a UI mostra as primeiras 1 000.
- Grid somente leitura; edição inline, paginação e filtro chegam na fase 4.
- Sem autocomplete, snippets ou consultas prontas ainda (fase 3).
- Histórico limitado a 200 entradas por conexão/banco.

## Requisitos

- macOS 26 ou superior
- Xcode 26 / Swift 6.3
- PostgreSQL local ou remoto para testar (opcional)

## Como rodar

```bash
scripts/run.sh          # compila em release, monta dist/herd.app e abre
```

Ou, separadamente:

```bash
scripts/build-app.sh    # gera dist/herd.app
open dist/herd.app
```

Na primeira execução, clique em **+** na sidebar para cadastrar uma conexão.

## Testes

```bash
swift test
```

O teste de integração com o Postgres fica desligado por padrão. Para rodá-lo contra
um servidor local (usuário atual, banco `postgres`, porta 5432):

```bash
HERD_TEST_PG=1 swift test --filter PostgresDriverTests
```

## Estrutura

```
Sources/
  HerdCore/                 biblioteca sem UI
    Models.swift            ConnectionConfig, DatabaseInfo, TableInfo, ColumnInfo, QueryResult
    SQLDialect.swift        quoting e LIMIT/TOP por engine
    DatabaseDriver.swift    protocolo async que todo driver implementa
    Postgres/PostgresDriver.swift  driver postgres-nio + formatação de células
    DriverRegistry.swift    um driver por conexão, compartilhado pelas janelas
    ConnectionStore.swift   JSON em Application Support
    Keychain.swift          senhas no Chaveiro
    SQLStatementSplitter.swift  separação de scripts em comandos e ranges
    SQLTokenizer.swift      tokens para realce de sintaxe
    QueryHistoryStore.swift histórico persistido por conexão/banco
  HerdDB/                   app SwiftUI
    HerdDBApp.swift         entrada, cena e menus
    AppModel.swift          estado global (conexões + drivers)
    WorkspaceState.swift    abas, seleção, sheets, execução/cancelamento
    ObjectTreeModel.swift   árvore lazy, filtro, seleção, reload
    QueryTab.swift          estado de uma aba
    UI/                     MainWindow, SidebarView, DetailView, QueryTabView,
                            QueryResultsView, SQLEditorView, ConnectionSheet
Resources/Info.plist        bundle id, versão, mínimo do sistema
scripts/build-app.sh        build release + bundle + assinatura ad-hoc
scripts/run.sh              build + open
docs/mockups/               referências visuais do projeto
```

## Onde ficam os dados

- Conexões: `~/Library/Application Support/herd-db/connections.json` (modo `0600`)
- Senhas: Chaveiro do macOS, serviço `com.juniorsilva.herd-db`, conta = UUID da conexão

## Roadmap

1. Esqueleto, driver Postgres, conexões, árvore ✅
2. Aba de consulta: editor real (NSTextView/TextKit 1), execução, cancelar, histórico ✅
3. Autocomplete contextual, snippets e consultas prontas
4. Grid de dados com paginação, filtro e edição inline com preview de SQL
5. Structure/DDL
6. FreeTDS + SQL Server
7. Backup/restore, novo banco, gerar scripts
8. Polimento, ícone, empacotamento
