# Сторонний код

## DynamicIslandShape (Sources/OverlayUI/DynamicIslandShape.swift)

Форма пилюли с вогнутыми верхними и выпуклыми нижними углами перенесена
практически без изменений из [Textream](https://github.com/f/textream)
(`NotchOverlayController.swift`, `struct DynamicIslandShape`).

```
MIT License

Copyright (c) 2026 Fatih Kadir Akin

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

Остальной оверлей (`OverlayGeometry.swift`, `AnswerOverlayPanel.swift`,
`AnswerOverlayWindowController.swift`, `OverlayStyle.swift`) написан заново
для нашей модели данных (стриминг текста от GPT, а не отслеживание речи по
заранее известному скрипту) — из Textream использовались только общие идеи
оконной механики (панель под вырезом, floating/fullscreen режимы,
`NSScreen`-геометрия), без копирования кода. Подробности — `docs/implementation-status.md`.
