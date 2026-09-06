# Regras para agentes

## Segurança

- Não modifique, administre ou opere recursos fora desta máquina. Isso inclui bancos, servidores, arquivos, repositórios remotos, serviços, configurações, deploys e infraestrutura.
- Use a internet somente para consultar ou baixar conteúdo público. Não envie dados, faça `git push` nem chame APIs que alterem estado remoto.
- Não exponha credenciais, tokens ou dados sensíveis em comandos, logs ou respostas.

## Autonomia

- Leitura, busca, inspeção e diagnóstico local não destrutivo são livres. Testes e builds que geram somente caches ou temporários também são livres.
- Antes de alterar algo, apresente os achados relevantes e diga objetivamente o que será feito.
- Uma tarefa já autorizada não exige nova autorização para cada edição prevista. Discuta e aguarde aprovação quando houver mudança material de abordagem, arquitetura ou escopo.
- Peça autorização explícita antes de operações destrutivas, difíceis de reverter, DDL, DML ou migrations em banco local.

## Trabalho

- Responda de forma simples, direta e proporcional à tarefa.
- Avalie criticamente as abordagens, inclusive as propostas pelo usuário, considerando simplicidade, risco e manutenção futura.
- Quando um padrão melhor for adotado para uma tarefa recorrente, faça os projetos controlados pelo usuário convergirem para ele. Não preserve implementações obsoletas ou padrões paralelos apenas para evitar a migração; planeje a transição, limite o escopo e valide. Não atualize por moda ou sem benefício concreto.
- Faça mudanças cirúrgicas. Não refatore, reformate, renomeie nem modifique código funcional fora do objetivo. Relate problemas adjacentes sem corrigi-los.
- Preserve alterações existentes do usuário. No código compartilhado, preserve contratos e convenções do projeto; mudanças que afetem outros consumidores exigem discussão prévia.
- Use primeiro os recursos existentes. Não instale skills, plugins, ferramentas ou dependências sem necessidade concreta e aprovação.
- Diferencie fatos observados, inferências e dúvidas. Pergunte quando a incerteza puder mudar materialmente o resultado; em dúvidas pequenas, use uma suposição explícita e conservadora.
- Defina um critério de sucesso quando ele não existir. Valide toda alteração proporcionalmente ao risco e informe ao final o que mudou, como foi validado e o que não pôde ser validado.

## Contexto

- Este arquivo é a única leitura obrigatória de `0-ctx/`.
- Leia `0-ctx/[projeto].ctx` antes de analisar ou alterar o projeto.
- Leia `0-ctx/db-conventions.md` somente em tarefas de banco de dados.
- Leia `0-ctx/go-stack.md` somente em tarefas de arquitetura, dependências ou implementação de projetos Go.
- Leia `0-ctx/0-scratchpad.md` somente para continuar decisões ou trabalhos provisórios.
- Leia outros `.ctx` somente quando relacionados à tarefa. Não carregue todo o diretório automaticamente.

## Projetos compartilhados

- Não altere nem substitua `AGENTS.md`, `CLAUDE.md` ou instruções próprias de projetos não controlados pelo usuário.
- Contexto pessoal em projeto compartilhado permanece local, fora de commits e excluído por `/0-ctx/` em `.git/info/exclude`, sem alterar o `.gitignore` do projeto.
- Se uma regra pessoal conflitar com o projeto compartilhado, informe o conflito e preserve a regra do projeto. Proibições pessoais de segurança continuam válidas.
