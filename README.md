# Ecloud - Escritório Cloud

Sistema Oracle APEX para escritórios de contabilidade, integrado às
calculadoras da Reforma Tributária do Consumo (RTC) da Receita Federal:
simulações do Regime Regular (CBS/IBS/IS) e do Simples Nacional, geração de
DANFSe, consultas de apoio (cClassTrib, CST, NCM/NBS, atividades do Simples) e
dashboard por escritório.

* Arquitetura e decisões: [docs/01-arquitetura.md](docs/01-arquitetura.md)
* Contratos das APIs: [docs/contratos/](docs/contratos/README.md)
* Banco: [db/](db/) (instalação em `db/instalar.sql`)
* App APEX 26.2 em APEXlang: [apex/](apex/) – páginas e validação em [docs/02-app-apex.md](docs/02-app-apex.md)

## Status

| Fase | Conteúdo | Situação |
|---|---|---|
| 1 | Arquitetura, DDL, constraints, índices, VPD, specs dos pacotes | aprovada em 26/11/2026 |
| 2 | Package bodies + testes (offline e integração com as calculadoras) | aprovada em 26/11/2026 |
| 3 | App em APEXlang (a partir do example-0), validado com apexlang-compile | entregue, aguardando aprovação |
| 4 | Deploy com apexlang-deploy (só com autorização) | – |
