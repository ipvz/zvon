# Formular

Положите сюда файлы шрифта Formular — приложение зарегистрирует любой `.otf`/`.ttf`
из бандла при запуске (`FontLoader.registerBundledFonts`).

Ожидаемые начертания (минимум):

- `Formular-Regular.otf`
- `Formular-Medium.otf`

PostScript-имя семейства должно быть `Formular` (так его ищет `Font.custom("Formular", …)`).
Пока файлов нет — интерфейс использует системный шрифт как технический fallback.
