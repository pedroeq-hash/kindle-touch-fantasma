# Kindle com toque fantasma

Um Kindle com o painel de toque danificado "apertava sozinho" e virava inutilizável. Em vez de descartar o aparelho,
medi onde caem os toques fantasmas e escrevi um plugin para o [KOReader](https://github.com/koreader/koreader) que
**só aceita toques nas áreas da tela que ainda funcionam** e serve uma **página web** para enviar e escolher livros pelo celular.

Resultado: o aparelho voltou a ser usado como leitor no dia a dia, sem nenhuma página virada pelos fantasmas.

<p align="center"><img src="docs/foto-kindle.jpg" width="340" alt="O Kindle de capa azul sobre um tecido vermelho, com o KOReader aberto em A Cartomante, de Machado de Assis"></p>

> Projeto pessoal e independente, sem relação com a Amazon. Os livros usados vêm de fontes sem DRM
> (domínio público e lojas que vendem sem DRM).

## O problema

| Item | Valor |
|---|---|
| Aparelho | Kindle básico, 11ª geração (2022, código KT5) |
| Tela | E-ink 6", 1072 x 1448 px, touch capacitivo (controlador Goodix) |
| Botões físicos | Só o de ligar: **sem touch, não dá para virar página** |

**Diagnóstico pelos logs do sistema** (comando `;dm` do Kindle):

- Cerca de 560 eventos de toque em 6 minutos de uso mínimo, com o controlador "vendo" até 9 dedos ao mesmo tempo.
- Toques alinhados em faixas horizontais (y fixo, x variando), repetidos a cada fração de segundo: padrão típico de
  linha do digitizer com defeito.
- O driver não registra nenhum erro (sem falha de I2C), e os fantasmas aparecem também fora do carregador.

Conclusão: **defeito de hardware no painel de toque**, não de software.

**Consertar não compensa**: a tela com touch custa cerca de R$ 200, e um Kindle usado da mesma geração sai por cerca de R$ 300.

## A solução

```
toque cru (/dev/input) ──► filtro do plugin ──► aceito?  ── sim ──► avança / volta página
                                                 └── não ──► descartado antes do KOReader

celular ──► página web servida pelo Kindle ──► enviar, abrir, renomear e apagar livros; ir para página; Wi-Fi
```

1. **Desbloqueio** do aparelho (jailbreak SpiderCat) para poder rodar o KOReader. Passo a passo em [docs/jailbreak.md](docs/jailbreak.md).
2. **Plugin `leitor.koplugin`** ([main.lua](koreader/plugins/leitor.koplugin/main.lua)), que:
   - substitui o tratador de toque do KOReader por um **filtro**: só passa toque de **1 dedo**, com **duração humana**
     (45 a 800 ms), **quase parado** (até 40 px) e **dentro de uma das duas áreas** (avançar e voltar);
   - **grava os eventos crus** do touch num log, para calibrar as áreas;
   - serve uma **página web** no próprio Kindle, usada pelo celular.

## Como as áreas foram escolhidas: com dados

Com o filtro descartando quase tudo, o plugin gravou os toques crus em três sessões (17/11 e 25/11/2026, cerca de 5 horas no total).
O script [tools/mapa_toques.py](tools/mapa_toques.py) reconstrói cada toque (protocolo multitouch tipo B do Linux) e gera um mapa de calor em SVG.
Os logs estão em [dados/](dados/).

<p align="center"><img src="docs/mapa_toques.svg" width="400" alt="Mapa de calor dos toques na tela do Kindle: uma faixa horizontal de fantasmas no meio da tela, uma coluna perto de x 710 e as duas áreas aceitas tracejadas nos cantos de baixo"></p>

<p align="center"><sub>Vermelho: onde os toques caem (mais escuro, mais toques). Tracejado: as áreas aceitas, verde para voltar e azul para avançar.
As poucas células dentro das áreas são, quase todas, toques de verdade.</sub></p>

O que os dados mostraram:

- **569 toques**, 344 deles com 2 dedos "simultâneos", concentrados **numa faixa só: y 480 a 650** (linhas em y ≈ 496 e y ≈ 612).
- Uma **coluna de fantasmas** que mudou de lugar: em 17/11 ficava em x ≈ 763 (só embaixo); em 25/11, em x 702-718, da tela inteira.
  Ela continua fora das áreas, que começam em x 820.
- Os únicos fantasmas que já caíram dentro das áreas duraram **37 e 38 ms**. Os toques de verdade para virar página duraram **de 49 a 124 ms**.
- Toques de propósito nos quatro cantos confirmaram a orientação dos eixos.

**Áreas definitivas:** avançar em x 820-1072 e voltar em x 0-300, ambas em y 900-1448 (a metade de baixo das laterais).
**Duração mínima:** começou em 60 ms; a gravação de 25/11 mostrou que isso recusava 2 de 11 toques de verdade, e o mínimo passou para 45 ms.
**Simulando o filtro em todas as gravações, nenhum fantasma é aceito, e todos os toques de verdade para virar página são.**

## A página web

Servida pelo próprio Kindle (porta 8090), tudo embutido num só HTML, sem fonte nem script de fora:

<p align="center">
  <img src="docs/pagina-livro.jpg" width="320" alt="Página no celular: livro aberto com página atual e controle de fonte, botão de enviar livro e a biblioteca">
  <img src="docs/pagina-ajustes.jpg" width="320" alt="Página no celular: cadastro de rede Wi-Fi, gravação de toques e o botão de sair do KOReader">
</p>

- enviar livros (EPUB, PDF, MOBI, AZW3, FB2, CBZ, DJVU), vários de uma vez, com barra de progresso;
- abrir um livro no Kindle, renomear (a posição de leitura acompanha) e apagar;
- ver o livro aberto e a página atual, ir para uma página e mudar o tamanho da fonte (em EPUB, MOBI, AZW3 e FB2);
- ver a bateria;
- cadastrar redes Wi-Fi no Kindle (uso pensado: o hotspot do celular, para funcionar fora de casa);
- gravar toques e sair do KOReader (saída de emergência).

## Decisões técnicas

- **Regra de decisão isolada:** `classificar()` é uma função pura, com **autoteste** que roda ao carregar o plugin.
- **O filtro não pode ser desligado.** Sem ele, um toque fantasma sem coordenada `y` derruba o detector de gestos do
  KOReader. O plugin **reinstala o filtro** a cada evento de entrada, caso algo troque o tratador.
- **Caminhos validados** em toda rota que mexe em arquivo: sem `..`, sem caminho absoluto, sem arquivo oculto e só extensões de livro.
- **Upload seguro:** grava num arquivo temporário e só renomeia no fim; um envio interrompido não deixa livro corrompido.
- **Memória FAT:** recusa caracteres que a FAT não aceita e trata renomear só maiúsculas/minúsculas (a FAT não diferencia).
- **Rede instável:** confere o IP a cada 30 s, mostra o endereço novo na tela e, sem IP, religa o Wi-Fi a cada 2 min (por até 20 min).
- **Gravação longa:** durante a gravação, segura o Kindle acordado (o AutoSuspend do KOReader ignorava o `preventScreenSaver`).

## Problemas encontrados no caminho

| Sintoma | Causa | Correção |
|---|---|---|
| KOReader caía 3 s depois de abrir | Toque fantasma sem `y` quebrava o `gesturedetector` | Filtro ligado desde a partida |
| Gravação da noite teve só 20 min | AutoSuspend do KOReader suspendia após 15 min | `pause_auto_suspend` e `keepalive` durante a gravação |
| Botões da página não faziam nada | `<button>` sem `type` conta como `submit`, e o JS ignorava todo `submit` | Ignorar só o botão que pertence a um formulário |
| KOReader abriu um arquivo sozinho e caiu | O filtro tinha sido desligado pela página | O filtro deixou de ser opcional e é reinstalado se for trocado |
| Kindle não voltava ao Wi-Fi depois de o roteador reiniciar | O Kindle não reconecta sozinho nesse caso | Vigia de IP que religa o Wi-Fi |

O registro completo, com datas, está em [docs/jailbreak.md](docs/jailbreak.md).

## Limitações conhecidas

- **A página não tem senha.** Qualquer pessoa na mesma rede pode apagar livros ou cadastrar uma rede Wi-Fi. Pensado para a rede de casa ou o hotspot do celular.
- **O envio de arquivo trava a tela do Kindle** enquanto dura (leitura bloqueante do socket). Na prática, poucos segundos para um EPUB.
- **As áreas são deste aparelho.** Em outro Kindle com defeito, é preciso gravar e gerar o mapa de novo.
- **Uma atualização da Amazon pode fechar o jailbreak.** As atualizações ficam bloqueadas, mas o método depende da versão do firmware.

## Estrutura

```
koreader/plugins/leitor.koplugin/   plugin (main.lua) e metadados
tools/mapa_toques.py                mapa de calor e estatísticas a partir do log de toques
tools/teste_plugin.py               teste do plugin no PC (LuaJIT) com módulos falsos do KOReader
tools/teste_plugin_stubs.lua        os módulos falsos
docs/jailbreak.md                   passo a passo e diário do projeto
docs/mapa_toques.svg                mapa de calor das gravações
dados/                              logs crus das gravações de toque
```

## Como reproduzir

> Desbloquear o aparelho é por sua conta e risco. Confira a compatibilidade do seu firmware em
> [kindlemodding.org](https://kindlemodding.org) antes de qualquer passo.

1. Desbloqueie o Kindle e instale o KOReader (2025.04 ou mais novo), seguindo [docs/jailbreak.md](docs/jailbreak.md).
2. Com o Kindle conectado no PC (aparece como `D:` no Windows), copie o plugin:

   ```powershell
   Copy-Item -Recurse -Force koreader\plugins\leitor.koplugin D:\koreader\plugins\
   ```

3. Abra o KOReader: o endereço da página aparece na tela.
4. Para calibrar no seu aparelho: ligue **Gravar toques** pela página, deixe o Kindle parado por 30 a 60 minutos e gere o mapa:

   ```powershell
   python tools\mapa_toques.py D:\toques.log mapa_toques.svg --areas 820,900,1072,1448 0,900,300,1448
   ```

   Depois, ajuste `CONFIG` no topo do `main.lua`.

### Testes no PC

```powershell
python tools\mapa_toques.py --teste
python -m pip install --target <pasta> lupa
python -I tools\teste_plugin.py <pasta>
```

O segundo teste carrega o `main.lua` num LuaJIT (o mesmo do KOReader) com módulos falsos e confere a página e as rotas:
escape de HTML, caminhos maliciosos (`../../etc/passwd`), livro aberto que não pode ser apagado nem renomeado, validação do Wi-Fi, da página e dos limites da fonte.
A página gerada fica em `<pasta>\pagina.html`.

## Licença

[AGPL-3.0](LICENSE), a mesma do KOReader.
