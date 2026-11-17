# Ícones de marca

Arquivos PNG de 128 px usados no seletor de tipo de conexão.

- `postgres.png` — elefante do PostgreSQL (Slonik), arte oficial do projeto
  PostgreSQL. Fonte: <https://commons.wikimedia.org/wiki/File:Postgresql_elephant.svg>
  (licença PostgreSQL).
- `sqlserver.png` — ícone do Microsoft SQL Server 2025. Fonte:
  <https://commons.wikimedia.org/wiki/File:Microsoft_SQL_Server_2025_icon.svg>
  (marca da Microsoft; uso apenas para identificar o produto).

O `scripts/build-app.sh` copia esta pasta para `Contents/Resources/Branding`.
Se as imagens não estiverem no bundle, `DatabaseEngine.brandImage` devolve
`nil` e a UI cai no ícone vetorial (`iconSymbol`).
