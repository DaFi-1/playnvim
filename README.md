# 🎵 playnvim

Um reprodutor de áudio e música minimalista e elegante para Neovim, com controle via **mpv IPC**, suporte a playlists do YouTube e arquivos locais, equalizador animado e miniaturas visuais.

---

## 💡 Como Funciona

O **playnvim** inicia uma instância do `mpv` em segundo plano desacoplada do Neovim, comunicando-se por meio de um socket IPC.
* Não trava nem congela a interface do Neovim enquanto toca ou carrega músicas.
* Permite fechar a janela do player a qualquer momento (`q` ou `<Esc>`) enquanto o áudio continua tocando normalmente em segundo plano.
* Exibe equalizador gráfico dinâmico, barra de volume vertical e suporte a miniaturas/capas usando o protocolo gráfico Kitty.

---

## 📦 Dependências

Antes de usar o plugin, certifique-se de ter os seguintes programas instalados no sistema:

| Dependência | Descrição | Como Instalar (Linux / Mac) |
|---|---|---|
| **Neovim** (>= 0.9.0) | Editor de texto | `sudo apt install neovim` / `brew install neovim` |
| **mpv** | Motor de reprodução de áudio | `sudo apt install mpv` / `sudo pacman -S mpv` / `brew install mpv` |
| **yt-dlp** | Suporte a streaming de links do YouTube | `sudo apt install yt-dlp` ou `pip install yt-dlp` |
| **sqlite3** *(opcional)* | Cache local de capas/thumbnails | `sudo apt install sqlite3` (já nativo na maioria das distribuições) |

> **Nota para miniaturas visuais**: Para ver as capas dos vídeos/músicas, use um emulador de terminal compatível com o Kitty Graphics Protocol (ex: Kitty, Ghostty, WezTerm). Em outros terminais o player funciona normalmente no modo de layout clássico.

---

## 🚀 Instalação

### Usando `lazy.nvim`

```lua
{
  "DaFi-1/playnvim",
  config = function()
    require("playnvim").setup({
      volume = 30,           -- Volume inicial (0 a 100)
      auto_next = true,      -- Tocar próxima faixa automaticamente
      keymap = "<space>a",   -- Atalho global opcional para alternar o player
      playlist = {
        {
          playlist = "LOFI",
          title = "Lofi Hip Hop - Beats to Relax",
          url = "https://www.youtube.com/watch?v=jfKfPfyJRdk",
        },
        {
          playlist = "LOFI",
          title = "Final Fantasy VII LoFi Mix",
          url = "https://www.youtube.com/watch?v=_PEQhKUDRNU",
        },
        {
          playlist = "LOCAL",
          title = "Minha Música Local",
          url = "/caminho/para/musica.mp3",
        },
      },
    })
  end,
}
```

### Usando `packer.nvim`

```lua
use({
  "DaFi-1/playnvim",
  config = function()
    require("playnvim").setup({
      volume = 30,
      auto_next = true,
      keymap = "<space>a",
    })
  end,
})
```

---

## 🎮 Comandos do Plugin

Todos os comandos podem ser executados no modo de comando do Neovim (`:`):

| Comando | Descrição e Exemplo de Uso |
|---|---|
| `:Play` ou `:PlayNvim` | Abre a janela centralizada do reprodutor musical |
| `:PlayToggle` | Abre o player se estiver fechado, ou fecha se estiver aberto |
| `:PlayPause` | Alterna entre Pausar e Continuar a reprodução |
| `:PlayResume` | Retoma a reprodução da música atual |
| `:PlayStop` | Para a reprodução de áudio |
| `:PlayNext` | Pula para a próxima música da playlist |
| `:PlayPrev` | Volta para a música anterior da playlist |
| `:PlayVolume <0-100>` | Define o volume desejado diretamente (ex: `:PlayVolume 50`) |
| `:PlayLayout [modo]` | Alterna ou escolhe o layout: `embedded`, `external` ou `classic` (ex: `:PlayLayout embedded`) |

---

## ⌨️ Teclas de Atalho (Dentro do Player)

Ao abrir a interface do player (`:Play`), você pode controlar tudo pelo teclado:

* `h` / `l` ou `←` / `→`: Navega horizontalmente entre os botões de ação do topo.
* `j` / `k` ou `↓` / `↑`: Desce ou sobe entre a barra de botões e as músicas da playlist.
* `<Enter>`: Executa a ação do botão selecionado ou toca a música escolhida.
* `<Space>`: Pausa ou despausa a música atual.
* `s`: Para a reprodução (Stop).
* `r`: Reinicia a música atual do início.
* `+` / `-`: Aumenta ou diminui o volume em passos de 5%.
* `>` / `<`: Próxima ou faixa anterior.
* `q` ou `<Esc>`: Fecha a janela do player (o som continuará tocando em segundo plano).
* `?`: Abre a ajuda rápida com a lista de atalhos.

---

## 📄 Licença

Este projeto está licenciado sob os termos da **MIT License**. Veja o arquivo [LICENSE](LICENSE) para mais detalhes.

```text
MIT License

Copyright (c) 2026 DaFi-1

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
