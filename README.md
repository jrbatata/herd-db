# herd-db

Gerenciador de bancos nativo para macOS — PostgreSQL agora, SQL Server na fase 6.
Interface em português, SwiftUI + AppKit, sem Electron.

![Visão geral](docs/mockups/visao-geral.png)

## Fase 1 — o que já funciona

- Janela nativa com `NavigationSplitView`, sidebar estilo pgAdmin e abas de consulta.
- Árvore conexão → banco → schema → tabelas/views → colunas, com carregamento sob demanda,
  filtro de objetos e menu de contexto nativo por tipo de nó.
- Driver PostgreSQL (`postgres-nio`) com descoberta de bancos, schemas, tabelas, views,
  colunas, chaves primárias e estrangeiras.
- Gerenciador de conexões: metadados em JSON, senha no Chaveiro do macOS, teste de conexão.
- Aba de consulta mínima: SQL, execução com `⌘↵` e grid de resultados somente leitura
  (suficiente para validar o driver; editor e grid completos chegam nas fases 2 e 4).
- Light/dark automáticos, componentes e menus 100% do sistema.

Limitações conhecidas desta fase:

- SQL Server aparece na lista de tipos como "em breve" e não conecta.
- Apenas um comando por execução (protocolo estendido do Postgres).
- Resultados limitados a 20 000 linhas em memória; a UI mostra as primeiras 1 000.
- Sem cancelamento, histórico, autocomplete ou edição de dados ainda.

## Requisitos

- macOS 26 ou superior
- Xcode 26 / Swift 6.3
- PostgreSQL local ou remoto para testar (opcional)

## Como rodar

```bash
scripts/run.sh          # compila em release, monta dist/herd-db.app e abre
```

Ou, separadamente:

```bash
scripts/build-app.sh    # gera dist/herd-db.app
open dist/herd-db.app
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
  HerdDB/                   app SwiftUI
    HerdDBApp.swift         entrada, cena e menus
    AppModel.swift          estado global (conexões + drivers)
    WorkspaceState.swift    abas, seleção, sheets
    ObjectTreeModel.swift   árvore lazy, filtro, seleção, reload
    QueryTab.swift          estado de uma aba
    UI/                     MainWindow, SidebarView, DetailView, QueryTabView,
                            QueryResultsView, ConnectionSheet
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
2. Aba de consulta: editor real (NSTextView/TextKit 2), execução, cancelar, histórico
3. Autocomplete contextual, snippets e consultas prontas
4. Grid de dados com paginação, filtro e edição inline com preview de SQL
5. Structure/DDL
6. FreeTDS + SQL Server
7. Backup/restore, novo banco, gerar scripts
8. Polimento, ícone, empacotamento
