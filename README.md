# Executando um cluster distribuído

Para executar o sistema distribuído, é necessário iniciar **três ou mais nós**. Cada nó pode ser executado em:

* uma máquina virtual (VM);
* um container; ou
* um processo independente.

Todos os nós devem possuir a linguagem **GNU Guile** instalada. Recomenda-se utilizar o sistema **Guix**, que já oferece suporte nativo ao GNU Guile.

Cada nó deve executar o arquivo:

```bash
guile algorithms.scm
```

## Obtendo o `sturdyref`

Ao iniciar, cada nó exibirá uma mensagem semelhante à seguinte:

```text
>>> NODE STURDYREF:<sturdyref>
```

O valor `<sturdyref>` identifica unicamente o nó e será utilizado para estabelecer conexões entre os peers.

## Conectando os nós

Para conectar um nó a outro, utilize o comando:

```text
connect <sturdyref>
```

onde `<sturdyref>` é o identificador do nó de destino.

### Exemplo

Suponha três nós:

* Nó A
* Nó B
* Nó C

Se desejar que todos os nós consigam se comunicar entre si, cada nó deve estabelecer conexão com os outros dois.

No terminal do **Nó A**:

```text
connect <sturdyref-do-B>
connect <sturdyref-do-C>
```

No terminal do **Nó B**:

```text
connect <sturdyref-do-A>
connect <sturdyref-do-C>
```

No terminal do **Nó C**:

```text
connect <sturdyref-do-A>
connect <sturdyref-do-B>
```

> **Importante:** As conexões **não são bidirecionais**. Quando o nó **A** executa `connect` para o nó **B**, isso **não** faz com que **B** se conecte automaticamente a **A**. Cada conexão deve ser criada explicitamente.

Em um cluster com **N** nós, cada nó deve executar `N - 1` comandos `connect`, um para cada outro nó do sistema, caso se deseje uma topologia totalmente conectada.

## Comandos disponíveis

Após estabelecer as conexões, utilize o comando:

```text
help
```

para visualizar os comandos disponíveis:

```text
help                       - exibe esta ajuda
connect <sturdyref>        - conecta a um peer
send <id> <text>           - envia uma mensagem para outro nó
lock-mutex                 - solicita o mutex distribuído
unlock                     - libera o mutex distribuído
elect                      - inicia uma eleição de líder
election                   - exibe o estado da eleição (fase, rodada e tempo restante)
host-resource              - cria e compartilha um recurso distribuído
connect-resource <sref>    - conecta-se a um recurso compartilhado
write <text>               - escreve no recurso (requer posse do mutex)
read                       - lê o conteúdo do recurso
peers                      - lista os peers conectados
status                     - exibe o estado do nó (ID, relógio lógico e token)
leader                     - mostra o líder atual
quit                       - encerra a execução
```

## Fluxo de uso

Uma sequência típica de utilização do sistema é:

1. Iniciar todos os nós.
2. Copiar o `sturdyref` de cada nó.
3. Conectar os nós utilizando o comando `connect`.
4. Verificar as conexões com `peers`.
5. Utilizar os demais comandos para testar o sistema distribuído, como envio de mensagens, eleição de líder, mutex distribuído e compartilhamento de recursos.
