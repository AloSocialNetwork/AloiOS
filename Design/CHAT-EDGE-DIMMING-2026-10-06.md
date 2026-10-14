# Затемнение краёв чата — 6 октября 2026

Запрос: сохранить именно чёрное затемнение сверху/снизу, как в тёмном чате
Telegram, но не прежние чрезмерные полосы. Удаление чёрного слоя в предыдущем
проходе было неверным: была прочитана только обычная wallpaper-композиция.

## Что найдено в исходниках Telegram

Проверен commit `6ad963e5b62d354da79040f388ae2b9132fb17b8`:

- `DefaultDarkPresentationTheme` задаёт default pattern с `intensity: -34`.
- `WallpaperBackgroundNode.updatePatternPresentation` определяет inverted
  pattern через отрицательную intensity и передаёт это состояние edge-узлам.
- `WallpaperEdgeEffectNodeImpl.updatePattern` ставит `overlayNode` в `.black`
  для inverted pattern; `.clear` относится к другой ветке обоев.
- `ChatControllerNode` задаёт edge alpha 0.75 для узорчатых обоев, верхний fade
  80 pt и расширение 34 pt; нижний fade 60 pt и расширение 20 pt.
- У Telegram сверху отдельный небольшой private variable blur, снизу
  `blur: false`. Этот приватный renderer в Alo не перенесён.

Источники: [тёмная тема](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramPresentationData/Sources/DefaultDarkPresentationTheme.swift),
[wallpaper](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/WallpaperBackgroundNode/Sources/WallpaperBackgroundNode.swift),
[edge overlay](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/WallpaperBackgroundNode/Sources/WallpaperEdgeEffectNodeImpl.swift),
[chat layout](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Sources/ChatControllerNode.swift).

## Изменения Alo

- Один чёрный слой с alpha 0.68 и компактной выборкой reference-mask.
  Дублирующий `.dark` UIKit backdrop в edge удалён. Стекло самих кнопок,
  поля ввода, верхних панелей и полноэкранный scrim меню не изменены.
- Fade фиксирован по длине: он не растягивается через всю клавиатуру и не
  расширяется сам по себе при добавлении панели проигрывания.
- Нижняя подложка по-прежнему продолжается под закруглённые углы клавиатуры.
- После просьбы «чуть-чуть поменьше» alpha уменьшена с 0.75 до 0.68,
  расширение в историю — с 34 до 28 pt сверху и с 20 до 16 pt снизу.
  Это небольшая настройка Alo по просьбе пользователя, не буквальные
  константы Telegram. Кривая fade 80 / 60 pt, safe areas и размеры контролов
  не изменены; при клавиатуре используется тот же нижний extension.
- Apple Design повлиял на разделение chrome и затемнения, отсутствие
  перехвата касаний, Reduce Transparency / Increase Contrast: одноцветная
  чёрная опора вместо полупрозрачного материала, с тем же локальным fade.
- Alo применяет эту композицию к своему тёмному чату, а не вводит целиком
  wallpaper inversion model Telegram. Это не заявление о буквальном
  совпадении всех вариантов тем или private blur.

## Проверки

UI-проверки используют яркие диагностические обои: затемнение должно быть
реально чёрным у края, не исчезнуть и не стать двойной непрозрачной полосой;
цвет обоев должен восстановиться сразу за chrome. Отдельно снимается
тёмный Night Accent, проверяются клавиатура, панель ГС/кружка и accessibility.

Первоначальный вариант (alpha 0.75): сборка и тесты прошли, 25 тестов /
66 запусков на 402 pt и 375 pt, 0 failures.
Результат: `/private/tmp/alo-20261006-dark-dimming.xcresult`.

Вручную просмотрены тёмный Night Accent (native и legacy), яркие
диагностические обои, клавиатура и панель кружка. Скриншоты сохранены в
`Design/Verification/2026-10-06-dimming/`.

Оба симулятора на iOS 26.2; legacy glass принудительно включён в части
проверок. Это не проверка на физическом iOS 18, не полный аудит всех экранов
и не измерение FPS. Геометрия других элементов чата не менялась.

Повторный прогон после небольшого ослабления (alpha 0.68, extensions 28 / 16):
25 тестов / 66 запусков на обоих размерах, 0 failures; сборка успешна.
Результат: `/private/tmp/alo-20261006-soft-dimming.xcresult`.
Тёмные native/legacy и клавиатура повторно просмотрены; скриншоты:
`Design/Verification/2026-10-06-dimming-soft/`. Ограничения платформы те же.
