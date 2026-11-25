# Passo a passo: jailbreak, KOReader e plugin

Registro do que foi feito. Atualize as datas e os desvios conforme for executando.

## Fase 0: preparar (feito em 17/11/2026)

- [x] Firmware conferido: `Kindle 5.19.2.0.1 (474059 001)` em `D:\system\version.txt`.
- [x] Backup de `D:\documents` em `%USERPROFILE%\Documents\kindle-backup-2026-11-17` (165 arquivos, 159 MB).
- [x] Armazenamento cheio com `D:\enchimento\enchimento1..4.dat` (13,4 GB), para a Amazon não conseguir baixar
      atualização durante o jailbreak. Não há `.bin` na raiz do `D:`.
- [x] Wizard (https://kindlemodding.org/jailbreak-wizard.html) recomendou o **SpiderCat** para KT5 + 5.19.2.0.1.

## Resultado (17/11/2026)

- [x] SpiderCat rodou: `D:\documents\JAILBROKEN.txt` = "You are jailbroken! (jb.sh v2.6.0)". Firmware continua 5.19.2.0.1.
      `spidercat.azw3` SHA-256 `3e2e3922…a72294b`.
- [x] `D:\enchimento` apagado à mão pelo Explorer. 13,4 GB livres e nenhum `update*.bin`.
- [x] KOReader **v2026.07.1** instalado em `D:\koreader` via KPM. Ao abrir sem o plugin, ele **caiu em 3 s**: um toque
      fantasma sem `y` quebrou o `gesturedetector.lua:869` (veja `D:\koreader\crash.log`). Por isso o plugin já vem com o filtro ligado.
      O touch é `/dev/input/event1` (`goodix-ts`) e o botão de ligar é `/dev/input/event0` (`bd71828-pwrkey`).
- Como instalar o KOReader via KPM, que o jailbreak já instala. Na busca da tela inicial, com Wi-Fi: `;kpm update`, depois
      `;kpm install koreader`, depois abrir pelo Scriptlet novo ou com `;kpm launch koreader`.
      Fonte: https://kindlemodding.org/jailbreaking/whats-next/getting-koreader/

## Fase 1: jailbreak com SpiderCat

Por que o SpiderCat: o arquivo vai por USB e basta abrir o livro. O Véra (KT5 de 5.17.1 a 5.19.2) pede vários toques
no navegador e no menu de fontes. Ele fica de reserva: https://kindlemodding.org/jailbreaking/Vera/

1. Baixar `spidercat.azw3` em https://kindlemodding.org/jailbreaking/SpiderCat/ e copiar para `D:\documents`.
2. Ejetar o Kindle. **Ligar o Wi-Fi** (o SpiderCat precisa dele) e abrir o livro "SpiderCat" na biblioteca.
3. Esperar: a tela pode ficar em branco alguns segundos e depois o texto rola. Ignorar janelas de "application error".
   No fim aparece "Restarting Kindle" e ele reinicia já desbloqueado.
   - Se a última linha disser `abort:no-firm`, o firmware não é aceito: parar e conferir o wizard.
4. Depois de reiniciar: conectar no PC, **apagar `D:\enchimento`** e qualquer `.bin` na raiz. As atualizações ficam bloqueadas pelo jailbreak.
5. Seguir a seção "What's Next" do kindlemodding: hotfix, KUAL/MRPI e **KOReader**.
   Usar KOReader de **2025.04 ou mais novo** (o servidor HTTP interno tinha um bug antes disso).
6. **Não** configurar o KOReader para iniciar junto com o Kindle por enquanto. Reiniciar segurando o botão de ligar
   sempre volta para o Kindle normal, e essa é a saída de emergência.

Anotar aqui: data, versão do KOReader instalada e qualquer desvio.

## Instalar o plugin

Com o Kindle conectado no PC:

```powershell
Copy-Item -Recurse -Force koreader\plugins\leitor.koplugin D:\koreader\plugins\
```

Abrir o KOReader. O endereço da página aparece por 8 segundos. Ele também fica no menu
**Ferramentas → Mais ferramentas → Leitor (touch e página) → Mostrar endereço da página**.
Vale reservar o IP do Kindle no roteador e salvar a página na tela inicial do celular.

## Fase 2: medir onde caem os fantasmas

1. O **Filtro de toque** já vem ligado. Com as áreas provisórias, quase tudo é descartado, e assim os fantasmas não
   mexem no KOReader nem o derrubam. **Não desligue o filtro**: sem ele o KOReader cai.
2. Pela página, ligar **Gravar toques**. Deixar o Kindle parado de 30 a 60 minutos.
3. No fim, tocar devagar nos quatro cantos da tela: superior esquerdo, superior direito, inferior direito e inferior esquerdo,
   nessa ordem. Isso confirma a orientação dos eixos.
4. Desligar **Gravar toques**, conectar no PC e gerar o mapa:

```powershell
python tools\mapa_toques.py D:\toques.log mapa_toques.svg --areas 700,1150,1072,1448 0,1150,372,1448
```

O SVG mostra em vermelho onde os toques caem. As áreas atuais aparecem tracejadas: azul para avançar, verde para voltar.
Com isso, escolhemos as duas áreas limpas e ajustamos `CONFIG` no topo de `koreader/plugins/leitor.koplugin/main.lua`.

## Fase 3 e 4: uso no dia a dia

- Com o filtro ligado, só toques curtos de um dedo nas duas áreas viram a página.
- Pela página: enviar EPUB/PDF/MOBI/AZW3/FB2/CBZ/DJVU (vários de uma vez, com barra de progresso); tocar no livro para abri-lo
  no Kindle; apagar livros com a lixeira (o livro aberto não pode ser apagado, e a posição e as anotações vão junto); ligar ou desligar
  a gravação; e **Sair do KOReader**, que é a saída de emergência se algo travar.
- **Redes Wi-Fi pela página:** nome e senha vão para o próprio Kindle (`NetworkMgr:saveNetwork`, a mesma função do menu de Wi-Fi
  do KOReader), e ele entra sozinho quando a rede estiver por perto. Uso recomendado: cadastrar o **hotspot do celular**. Assim,
  em qualquer lugar, basta ligar o hotspot e, se quiser, cadastrar a rede do local pela página. **Testado em 17/11/2026:** o dono
  cadastrou o hotspot, desligou o roteador e o Kindle entrou no hotspot sozinho.
- 18/11/2026: a página mostra a **bateria** (`Device:getPowerDevice()`), **renomeia** livros (lápis; mantém pasta e extensão, leva junto
  a posição de leitura com `DocSettings.updateLocation` e recusa o livro aberto e os caracteres que a FAT não aceita) e, no cartão
  "Lendo agora", tem **Página [15] / 257 · Ir** (evento `GotoPage`, o mesmo do "ir para página" do KOReader). **Renomear e ir para página testados pelo dono (25/11/2026): funcionam.**
- 25/11/2026: no cartão "Lendo agora", **Fonte [A−] 22 [A+]** muda o tamanho da fonte de 2 em 2 (evento `SetFontSize`, o mesmo do
  menu de fonte do KOReader, com os mesmos limites de 12 a 255). Só aparece em livros com texto ajustável (EPUB, MOBI, AZW3, FB2), não em
  PDF, CBZ ou DJVU. Depois do ajuste a página recarrega, porque o total de páginas muda. **Testado pelo dono em 25/11/2026: funciona.**
- Na primeira versão da página nova, os botões de abrir livro, gravar e sair não faziam nada: um `<button>` sem `type` conta como
  `submit`, e o JavaScript ignorava todos os `submit`. Corrigido em 17/11/2026 (agora ignora só o botão que pertence a um formulário).
  O `.txt` saiu da lista porque em `documents` só havia logs do sistema e o `My Clippings`.
- Teste do plugin no PC, sem o Kindle, antes de copiar: `python -m pip install --target <pasta> lupa` e depois
  `python -I tools\teste_plugin.py <pasta>`. Ele confere a sintaxe no LuaJIT (o mesmo do KOReader), a página e as rotas,
  usando módulos falsos do KOReader (`tools/teste_plugin_stubs.lua`), e salva a página gerada em `<pasta>\pagina.html`.

## Confirmado no aparelho (17/11/2026)

- O filtro entra na partida e segura os fantasmas: sessões de vários minutos, com o Kindle dormindo e acordando, sem cair.
- A página respondeu em `http://<ip-do-kindle>:8090` (achada pela rede a partir do PC) e o botão **Sair do KOReader** fecha limpo (exit code 0).
- O framebuffer é 1072x1448 e o KOReader reconhece o aparelho como `KindleBasic4`.
- Quando o Kindle dorme, o Wi-Fi e a página caem. Ao acordar, a página volta e o endereço aparece de novo.

## Gravação da noite de 17/11/2026 (00h53 às 09h06)

- Só ~20 min foram gravados: das 01h11 às 09h05 o Kindle **dormiu**. O culpado é o **AutoSuspend do KOReader**, que suspende
  depois de 15 min sem interação e ignora o `preventScreenSaver`. Correção: a gravação agora liga também `PluginShare.pause_auto_suspend`
  e `PluginShare.keepalive`. Sem queda no `crash.log`.
- 215 toques, 175 deles com 2 dedos. **Os fantasmas caem numa faixa só: y 480 a 650** (linhas em y≈496 e y≈612), sobretudo em x 900 a 1072,
  com alguns em x 0 a 200. Fora dessa faixa, só 5 toques, e os 2 de 1 dedo nas áreas provisórias (x≈1070, y≈1354 a 1384) duraram menos de 40 ms,
  então o filtro de duração já os descarta.
- Os 4 cantos **não** apareceram no log (provavelmente foram feitos com o Kindle dormindo). Precisa repetir.
- O log foi renomeado no Kindle para `D:\toques-2026-11-17-noite.log`, para a próxima gravação começar limpa.

## Gravação da tarde de 17/11/2026 (11h23 às 12h44)

- Gravou 1h20 **sem buraco**: a correção do AutoSuspend funcionou. A rede caiu no meio e a gravação seguiu, mas o Kindle não voltou ao
  Wi-Fi sozinho. Por isso o plugin agora confere o IP a cada 30 s, mostra o endereço novo na tela por 30 s e, se ficar sem IP,
  religa o Wi-Fi a cada 2 min (por até 20 min). A reconexão foi **confirmada pelo dono em 25/11/2026**.
- 171 toques; os fantasmas de novo em y 480-511 e 608-639. Apareceu também uma coluna em **x≈763, y 1290-1420**: 1 dedo, de 23 a 26 ms,
  e um de 150 ms arrastando 99 px.
- **Os 4 cantos bateram com a tela**: (51,63), (1004,80), (981,1376) e (86,1381). Os eixos estão certos.
  Os toques de propósito duraram de 350 a 520 ms.
- **Áreas definitivas: avançar x 820-1072, voltar x 0-300, ambas y 900-1448; duração de 60 a 800 ms.** (Em 25/11 o mínimo passou para 45 ms; veja "Logs de 18/11 a 25/11/2026".) Simulando nas duas gravações,
  nenhum fantasma é aceito. O único toque aceito foi às 09h06 da manhã, quando o dono mexia no aparelho, então deve ter sido real.
- Log arquivado em `D:\toques-2026-11-17-tarde.log`.
- **Para encerrar uma gravação sem a página, basta reiniciar segurando o botão de ligar.** O log é salvo a cada toque.
  Com o KOReader aberto, o cabo USB não monta o `D:`.

## Teste de leitura e queda (17/11/2026, 14h44 às 15h14)

- Livro aberto pela página às 14h44, parado por 15 min: **nenhuma página virou** e o Kindle **dormiu sozinho** às 15h00 (AutoSuspend). Ok.
- Acordou às 15h06 e **caiu às 15h14**: `gesturedetector.lua:326`, chamado pelo `handleTouchEv` **original** do KOReader. O filtro não estava agindo.
  Antes disso, às 14h43, uma gravação parou no meio de um toque depois de 3 s, e 8 s depois o KOReader abriu sozinho o
  `toques-…-tarde.log` (um toque fantasma chegou ao gerenciador de arquivos).
- **Causa confirmada pelo dono: o filtro foi desligado pela página.** Desligado, os fantasmas chegam ao KOReader: abrem arquivos sozinhos
  e, quando vem um contato sem `y`, derrubam o `gesturedetector`.
- Correções: o **filtro não pode mais ser desligado** (saiu da página, do menu e das configurações). O plugin **reinstala o filtro**
  a cada quadro de entrada se ele tiver sido trocado, e registra `Leitor: filtro de toque instalado` no `crash.log`.
  Se essa linha aparecer longe da abertura do KOReader, algo está trocando o tratador e vale investigar.

## Verificação no aparelho: concluída (25/11/2026)

Tudo o que estava pendente foi confirmado no Kindle:
- **Sair do KOReader** fecha limpo (exit code 0 em 17/11 e 18/11).
- O Kindle **hiberna sozinho durante a leitura** com o filtro ligado (17/11, 15h00).
- Pelo uso do dono, de 18/11 a 25/11:
  - **Ir para página** e **renomear** funcionam. Ao renomear, a **posição de leitura acompanha** o livro.
  - A **bateria** no topo da página está correta.
  - A **reconexão do Wi-Fi** funciona.
  - O **envio de arquivos grandes** funciona.
  - O **consumo de bateria** foi aceitável.

Se o defeito piorar (páginas virando sozinhas), grave de novo pela página e gere o mapa com `tools/mapa_toques.py`.

## Logs de 18/11 a 25/11/2026

- **`crash.log`: nenhuma queda** desde a de 17/11, 15h14. O filtro foi instalado só na abertura de cada sessão.
  Três sessões terminaram sem o "Tearing down" e sem erro (18/11 às 17h53 e 18h56, e a que começou às 18h56 só terminou em 23/11),
  o que indica reinício pelo botão ou bateria esgotada, e não queda.
- A reconexão aparece no log: em 23/11, das 15h52 às 16h04, o plugin religou o Wi-Fi a cada 2 min sem achar rede (provavelmente
  fora do alcance de qualquer rede salva) e o Kindle dormiu às 16h06, como previsto.
- **Houve uma gravação, mesmo sem intenção:** em 25/11, das 12h06 às 15h34, gravou 183 toques (arquivada em `D:\toques-2026-11-25.log`).
  O Kindle ficou acordado nesse período, porque gravar impede a hibernação.
- **A faixa horizontal continua em y 608-639** (123 toques, x de 84 a 1026). A linha de y≈496 não apareceu.
- **A coluna mudou:** antes em x≈763 (só y 1290-1420), agora em **x 702-718, de y 112 a 1440** (a tela inteira de cima a baixo).
  Fica fora das duas áreas: a área de avançar começa em x 820.
- **Nenhum fantasma foi aceito.** Os 11 toques de 1 dedo dentro das áreas foram do dono: estão nos cantos de baixo, em posições variadas
  (os fantasmas caem em linhas fixas) e vêm em pares de avançar e voltar. Eles duraram de **49 a 124 ms**, bem menos que os
  toques lentos de calibração (350-520 ms). Com o mínimo de 60 ms, **2 dos 11 foram recusados**: nos dois casos o dono tocou de novo
  um segundo depois.
- **Ajuste: duração mínima de 60 para 45 ms.** Os únicos fantasmas já vistos dentro das áreas duraram 37 e 38 ms (noite de 17/11),
  então continuam recusados. Simulando nas quatro gravações com 45 ms, nenhum fantasma passa.
