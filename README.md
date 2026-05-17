# Supertonic Mac

Локальный TTS для macOS (Apple Silicon) с тремя движками в одном SwiftUI-окне:

| Движок | Назначение | Скорость на M4 Pro | Лицензия |
|---|---|---|---|
| **Supertonic 3** | Английский + 30 языков, фиксированные голоса M1–F5 | RTF ~0.3× | Apache 2.0 |
| **Silero v4 (RU)** | Чистый русский, автоматические ударения, SSML | RTF ~0.1× | non-commercial |
| **F5-TTS (MLX, EN/ZH)** | Voice cloning, base lucasnewman/f5-tts-mlx | RTF ~2–3× | CC-BY-NC |
| **F5-TTS (MLX, RU)** | Voice cloning, Misha24-10/F5-TTS_RUSSIAN finetune | RTF ~3–4× | CC-BY-NC |
| **F5-TTS (torch, RU)** | Fallback если MLX-RU не установлен | RTF ~15× | CC-BY-NC |

`Auto`-режим переключает между Supertonic и Silero по доле кириллицы в тексте; F5 включается явно.

## Установка

### 1. Зависимости системы

```bash
brew install git-lfs uv
git lfs install
```

### 2. Клонировать апп

```bash
git clone https://github.com/gumbertnntu-cloud/supertonic-mac.git ~/projects/supertonic-mac
cd ~/projects/supertonic-mac/py
uv sync --python 3.12
```

Это поставит `onnxruntime`, `torch` (CPU-only), `f5-tts`, `omegaconf` и др. в локальный venv `~/projects/supertonic-mac/py/.venv/`.

### 2b. (опционально) Включить MLX-RU для F5

Если хочешь, чтобы клонирование голоса на русском работало быстро (RTF ~3–4× вместо ~15× через torch):

```bash
cd ~/projects/supertonic-mac/py
uv run setup_ru_mlx.py
```

Это скачает Misha24-10/F5-TTS_RUSSIAN (~1.3 ГБ) и положит файлы в `~/.cache/local-f5-misha-ru/` под именами, которые понимает `f5_tts_mlx`. После этого worker сам видит установку и роутит F5 для кириллицы через MLX.

### 3. Клонировать upstream Supertonic (для весов и `example_onnx.py`)

```bash
cd ~/projects
git clone https://github.com/supertone-inc/supertonic.git
cd supertonic
git clone https://huggingface.co/Supertone/supertonic-3 assets
cd assets && git lfs pull   # на случай если LFS не скачал все .onnx
```

### 4. Собрать .app

```bash
cd ~/projects/supertonic-mac/app
./build.sh
open Supertonic.app
```

Сборка идёт через `swiftc` напрямую (Xcode не требуется, достаточно Command Line Tools).

## Структура

```
supertonic-mac/
├── app/                  SwiftUI приложение
│   ├── Supertonic.swift  Весь код в одном файле
│   ├── Info.plist        Метаданные бандла
│   └── build.sh          Сборка .app через swiftc
├── py/                   Python скрипты (общий venv)
│   ├── pyproject.toml    Зависимости
│   ├── silero_synth.py   Silero CLI
│   └── f5_synth.py       F5-TTS CLI
├── voice_samples/        Пользовательские образцы (не в git)
└── README.md
```

`example_onnx.py` (Supertonic) и `assets/voice_styles/*.json` — в **upstream-клоне**
`~/projects/supertonic/`, не дублируются.

## Использование

1. Введи текст
2. Движок: `Auto` (рекомендуется), либо явно выбери `Supertonic`/`Silero (RU)`/`F5 (clone)`
3. Голос — список меняется в зависимости от движка
4. Play (⌘↩) или Экспорт WAV (⌘E)

Для F5 предварительно нужно добавить голосовой образец:
- Иконка «человек+» рядом с picker'ом голоса → **Добавить**
- Выбрать WAV/MP3 (5–15 сек чистой речи)
- Ввести транскрипцию (что именно говорится в файле) — обязательно для F5

Иконка `?` слева сверху — подсказка по паузам, ударениям, SSML и тегам.

## Roadmap

См. [Issues](https://github.com/gumbertnntu-cloud/supertonic-mac/issues):

- Автотранскрипция образцов через локальный GigaAM v3 (MLX)
- MPS-ускорение F5 на M4 Pro
- Persistent Python worker (одна загрузка моделей на сессию вместо холодного старта каждый раз)
- Запись с микрофона прямо из аппа
- Управление скоростью / шагами синтеза в UI
- Экспорт MP3

## Подводные камни

- **Python 3.13/3.14**: `onnxruntime 1.23.1` не имеет wheel'ов; используем 3.12.
- **F5 на CPU медленный**: torch backend даёт RTF ~5–20× (минута на 3 сек). MLX backend в ~7 раз быстрее (RTF ~2–3×), но базовая MLX-модель обучена на EN+ZH — русский звучит с английским акцентом. По умолчанию `f5_synth.py --backend auto` выбирает MLX для не-кириллицы, torch для кириллицы.
- **Холодный старт**: каждый клик Play поднимает новый Python-процесс. На Silero +~2 сек, на F5 +~5–10 сек. Persistent worker — отдельная задача.
- **Лицензии моделей**: Silero — non-commercial, F5 — CC-BY-NC. Supertonic — Apache 2.0, без ограничений.
