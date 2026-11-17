# CosmoSQLClient (cópia local)

Cópia reduzida do [CosmoSQLClient-Swift](https://github.com/vkuttyp/CosmoSQLClient-Swift)
na versão **1.6.4** (commit `8a9559be53b91307e7ffb15e1035dfee7ad23856`), licença MIT.

Mantivemos apenas `CosmoSQLCore` e `CosmoMSSQL`. O código em `Sources/` é o
original, com **duas alterações pequenas** em `CosmoMSSQL`:

1. `TDSDecoder` lê o `ENVCHANGE` de tipo 4 e expõe o tamanho de pacote TDS
   negociado no login (`packetSize`).
2. `MSSQLConnection.sendPacket` usa esse tamanho para fragmentar cada mensagem.
   Antes ele sempre usava 32 KiB; o SQL Server negocia 16 KiB e encerra a
   conexão (`NIOSSLError.uncleanShutdown`) ao receber um pacote maior. Isso
   quebrava scripts e `INSERT`s com mais de ~16 KB.

Sem essa correção, restaurar um `.sql` com textos, XML ou binários grandes
fecha a conexão no meio do processo.

Ao atualizar a dependência upstream, confira se o problema foi corrigido e,
se sim, remova esta cópia e volte para `.package(url:from:)` no `Package.swift`.

Para atualizar a cópia:

1. Copie `Sources/CosmoSQLCore` e `Sources/CosmoMSSQL` da nova versão.
2. Reaplique as duas alterações acima.
3. Atualize a versão e o commit deste README.
