# Relatório de performance — herd-db

Data: 16/11/2026  
Ambiente: macOS 27.2, Apple Silicon, build `release`

> **Atualização:** as correções de P0/P1 foram aplicadas e medidas. Os números originais ficam como referência de “antes”; a comparação está em **Rodada pós-correção**.

## Resumo executivo

O aplicativo inicia o processo rapidamente, mas uma instância recém-aberta manteve aproximadamente um núcleo de CPU ocupado durante o teste. A investigação comparativa confirmou que o consumo é causado por um ciclo de recriação do workspace e recarga da conexão, não pelo autocomplete. Esse é o gargalo de maior prioridade.

O editor também faz múltiplas passagens completas pelo script a cada tecla. Isso tende a ser percebido como atraso conforme o SQL cresce, mesmo quando a conexão está saudável.

## Resultados medidos

| Medição | Resultado |
|---|---:|
| Criação do processo | 127,5 ms |
| CPU entre 5–9 s após abrir | 101,5–103,2% |
| CPU após cerca de 30 s | 92,5% |
| RSS observado | 117–124 MiB |
| Physical footprint no `sample` | 46,4 MiB |
| Threads | 12 |
| Testes automatizados | 107 executados, 7 ignorados, 0 falhas |

Observação: criação do processo não equivale a “interface pronta para uso”. O projeto ainda não possui um marcador interno para medir o primeiro frame utilizável.

## Achados

### P0 — CPU alta sustentada após abrir

Evidências do perfil:

- CPU permaneceu entre 92% e 103% durante a janela observada.
- A amostragem encontrou novas inicializações de `MainWindow`, `WorkspaceState` e `ObjectTreeModel`, seguidas por `toggle`, `loadNode`, `PostgresDriver.listDatabases` e `PostgresClient.query`.
- Quando existe somente uma conexão, `ObjectTreeModel.syncConnections()` expande essa conexão automaticamente e inicia `listDatabases()`.
- Uma execução da mesma build com perfil temporário vazio, sem conexões, permaneceu em 0,0% de CPU durante cinco medições consecutivas.
- A conexão PostgreSQL estava ociosa no servidor, mas o processo continuava recompondo a interface e gerando tráfego/trabalho.

Causa confirmada: `MainWindow.init` cria `WorkspaceState(app:)` dentro de `State(initialValue:)`. A expressão é executada novamente quando o SwiftUI recria o valor da `View`, mesmo que o armazenamento de `@State` preserve a instância anterior. O novo workspace temporário inicializa a árvore, autoexpande a conexão e dispara outra consulta. As alterações de loading/log/UI provocam novas recomposições e realimentam o ciclo.

Recomendação:

1. Colocar o `WorkspaceState` em um contêiner estável por janela, cuja inicialização não tenha efeitos colaterais durante a recriação da `View`.
2. Manter a autoexpansão atual somente na instância efetivamente retida do workspace.
3. Adicionar teste/contador garantindo uma única criação do workspace e uma única chamada inicial de `listDatabases()`.
4. Como proteção adicional, deduplicar chamadas concorrentes de `listDatabases()` no driver e definir timeout/backoff.
5. Medir novamente CPU, tráfego e contagem de consultas após a correção.

Essa correção não toca em `SQLCompletionController`, `SQLCatalogStore` nem `SQLCompletionEngine`; portanto, não muda gatilhos, sugestões, ranking, snippets ou posição do cursor do autocomplete.

### P1 — Editor percorre o documento inteiro a cada tecla

Em cada `textDidChange`, o editor:

1. copia o texto para o estado SwiftUI;
2. tokeniza e reaplica atributos em todo o documento;
3. recalcula todos os inícios de linha;
4. inicia uma nova solicitação de autocomplete.

Esse custo é linear no tamanho do script e ocorre no thread principal. Scripts maiores devem apresentar atraso progressivo.

Recomendação:

- aplicar destaque apenas no intervalo/linhas alteradas;
- atualizar a régua incrementalmente;
- executar a função pura `SQLCompletionEngine.suggestions` fora do thread principal, mantendo a mesma validação de geração/texto/cursor antes de mostrar o popup;
- preservar o cancelamento atual e descartar resultados obsoletos exatamente como hoje;
- criar benchmark para scripts de 1 mil, 10 mil e 50 mil linhas.

Um debounce perceptível foi descartado como primeira opção porque mudaria o tempo de resposta do autocomplete. A otimização recomendada preserva o momento do gatilho e apenas tira o cálculo pesado do thread da interface.

### P2 — Cálculos derivados repetidos nos resultados

`filteredRows`, `basePageRows`, `pageRows` e `pageCount` são propriedades computadas encadeadas. `filteredRows` também materializa `Array(resultSet.rows.enumerated())`. O SwiftUI pode consultar essas propriedades várias vezes durante uma atualização.

A grade usa `LazyVStack` e paginação, o que já limita o custo de renderização, mas filtragem e cópias podem pesar com o limite máximo de resultados.

Recomendação:

- calcular o conjunto filtrado uma vez quando filtro/resultado mudar;
- evitar materializar todos os pares enumerados quando não há filtro;
- instrumentar filtros com 10 mil e 50 mil linhas.

### P2 — Árvore recompõe todas as linhas visíveis

`ObjectTreeModel.rows` reconstrói recursivamente o array de linhas em toda leitura. Em bancos com muitos schemas, tabelas e colunas, mudanças observáveis não relacionadas podem repetir esse trabalho.

Recomendação:

- armazenar/cachear linhas visíveis e invalidar apenas em expansão, carga ou filtro;
- medir árvores sintéticas com 1 mil, 10 mil e 50 mil nós.

## Teste do encerramento

O crash ao fechar foi reproduzido e identificado como recursão infinita no botão padrão de fechar. Após a correção:

- o botão vermelho encerrou a instância de teste;
- nenhum novo relatório de crash foi criado;
- os testes automatizados continuaram passando.

## Rodada pós-correção

Medições repetidas com a build `release` atual e a mesma conexão salva (`postgres local`, 127.0.0.1:5432, servidor ativo).

| Medição | Antes | Depois |
|---|---:|---:|
| CPU entre 5–9 s após abrir | 101,5–103,2% | 0,0–0,1% |
| CPU após cerca de 30 s | 92,5% | 0,0% |
| CPU instantânea (10 s / 32 s) | — | 1,0% / 0,0% |
| RSS observado | 117–124 MiB | 107 MiB no pico → 99 MiB aos 30 s |
| Testes automatizados | 107 | 117 (13 ignorados, 0 falhas) |

A queda para ~0% confirma que o ciclo de recriação do workspace foi eliminado: a árvore carrega a conexão uma vez, executa `listDatabases()` e permanece ociosa.

### Benchmarks (release)

`HERD_BENCH=1 swift test --filter SQLBenchmarkTests`

| Script | Tokenização | Autocomplete |
|---|---:|---:|
| 1.000 linhas | 4,4 ms | 8,7 ms |
| 10.000 linhas | 43 ms | 87 ms |
| 50.000 linhas | 217 ms | 439 ms |

O autocomplete de 50 mil linhas leva ~439 ms, mas agora roda fora do thread principal: a interface não bloqueia e o resultado é descartado se o texto ou o cursor mudar.

### O que ficou parcial

- O destaque ainda tokeniza o documento inteiro (fora da main) e reaplica atributos da linha editada até o fim; não é incremental por trecho.
- A régua não reescaneia o texto, mas filtra e ordena todo o array de linhas a cada tecla (`O(n log n)`).
- `listDatabases()` coalesce chamadas concorrentes, sem timeout/backoff.
- Falta instrumentar “primeira janela pronta” e um teste/contador de criação única do workspace (exige alvo de teste do app).

## Próxima rodada recomendada

1. Instrumentar “primeira janela pronta” para medir o tempo até a interface utilizável.
2. Criar teste/contador de criação única do workspace e de uma chamada inicial a `listDatabases()`.
3. Adicionar timeout/backoff às consultas de catálogo e à lista de bancos.
4. Tornar o destaque incremental por trecho e trocar o filtro+ordenação da régua por splice binário.
5. Criar benchmarks da grade (10 mil e 50 mil linhas) e da árvore (1 mil, 10 mil e 50 mil nós).
6. Repetir o perfil com Instruments Time Profiler e Allocations após cada nova mudança.
