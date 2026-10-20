# Ata

Grava e transcreve qualquer meeting (Slack, Zoom, Meet, Teams, FaceTime, browser…), **100% no teu Mac**.

App de barra de menus para macOS 14+ em Apple Silicon. Grava o teu microfone e o som do sistema em pistas separadas, e transcreve-as localmente com o Whisper (large-v3-turbo, na GPU). Nada sai do computador.

## Instalar

```bash
cd Ata
./install.sh
```

Na primeira vez abre-se uma janela de boas-vindas. Lá podes:

- dar as permissões de **microfone** e de **áudio do sistema**;
- instalar o motor **whisper.cpp** (via Homebrew);
- descarregar o modelo (1.6 GB, só uma vez).

## Usar

- **Gravar à mão:** clica no ícone de ondas e depois no botão vermelho (ou carrega em ⌘R com o menu aberto).
- **Deteção automática:** quando uma app começa a usar o micro, a Ata avisa-te com uma notificação com o botão "Gravar". Nas definições podes mudar para gravar automaticamente.
- Quando paras, a transcrição corre em segundo plano. Recebes uma notificação quando está pronta. Cada meeting fica em `~/Documents/Meetings/<data> <app>/transcricao.md`.

O menu mostra:

- o tempo de gravação;
- um medidor ao vivo para **ti** e outro para **os outros**, para veres logo que está tudo a ser captado;
- as últimas meetings. Clica para abrir, ou usa o botão direito para copiar o texto, transcrever de novo, mostrar no Finder ou apagar.

## O que torna isto fiável

- **Mudas de micro a meio** (ex.: ligas os AirPods): a gravação continua no mesmo ficheiro.
- **O micro deixa de responder:** é reiniciado sozinho.
- **O Mac adormece** ou a captura do sistema cai: reconecta-se automaticamente.
- **As duas pistas ficam alinhadas no tempo**, mesmo depois de reinícios.
- **A app crasha ou o Mac desliga:** o áudio fica guardado (o ficheiro é atualizado a cada 3 s) e é transcrito no próximo arranque.
- **Fechas a app a meio de uma gravação:** a gravação é fechada corretamente e transcrita quando voltares a abrir.
- **A transcrição falha:** o áudio nunca é apagado e há um botão "Tentar de novo".
- **Sem auscultadores:** a Ata remove as frases dos outros que o teu micro apanhou em eco.

## Definições

O teu nome na transcrição, o idioma (automático, PT, EN…), a deteção automática, parar sozinho quando a meeting acaba, guardar o áudio e abrir ao iniciar sessão.

## Notas

- Avisa sempre os participantes de que estás a gravar.
- Se recompilares a app, o macOS pode voltar a pedir a permissão de áudio do sistema. É normal com apps assinadas localmente.
- "Outros" junta todos os participantes remotos; ainda não distingue pessoas diferentes.
