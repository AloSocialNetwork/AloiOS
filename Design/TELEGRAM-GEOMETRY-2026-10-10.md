# Замеры Telegram iOS и геометрия Alo

## Область проверки

Проверены исходники официального Telegram iOS, commit
`6e370e06d147b091b07903071cb1b8a22152492d`. Это замеры **конкретных компонентов и
веток кода**, а не всех экранов Telegram и не сравнение установленного Telegram
на двух физических телефонах. Единицы — логические pt, не пиксели скриншота.
Базовый текст, compact layout телефона; другие темы, типы медиа и размеры текста
могут выбирать другую ветку. Клиент Alo остаётся SwiftUI/UIKit, транспорт — Alo.

Apple Design применён к непрерывности, слоям и управлению анимацией; Animate — к
назначению переходов и Reduced Motion, Write Swift — к отдельному состоянию
даты и файловым метаданным. UI/UX Pro Max — к границам элементов, области
нажатия и клавиатуре. У `apple-design-dickwu` отсутствуют обязательные
справочники `references/hig`, поэтому полный HIG-аудит не заявляется.

## Источники

1. [ChatMessageDateHeader](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageItemImpl/Sources/ChatMessageDateHeader.swift): строки 98, 319, 358–369, 720–807 — секция, шрифт, капсула, закрепление и alpha.
2. [ListView](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/Display/Source/ListView.swift): 799–854, 897–933, 3992–4016 — задержка скрытия, drag/deceleration, ограничение позиции заголовка секцией.
3. [ChatMessageItemCommon](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageItemCommon/Sources/ChatMessageItemCommon.swift): 133–158 — compact/regular размеры сообщений, изображений, видео, кружков.
4. [ChatMessageInteractiveMediaNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageInteractiveMediaNode/Sources/ChatMessageInteractiveMediaNode.swift): 949–994, 1169–1207 — aspect fitting, размеры исходника, ограничение высоты, специальные виды медиа.
5. [TGVideoMessageCaptureController](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/LegacyComponents/Sources/TGVideoMessageCaptureController.m): 318–353, 599–641 — диаметр камеры, положение, inset кольца, spring входа. Это legacy capture, используемый `LegacyInstantVideoController`, не редактор stories.
6. [TGModernConversationInputMicButton](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/LegacyComponents/Sources/TGModernConversationInputMicButton.m): геометрия микрофонного orb и пороги drag.
7. [ChatTextInputPanelNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift): 1289–1292, 1987–2009 — адаптивная высота ввода, apply/checkmark в редактировании.
8. [EditAccessoryPanelNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Sources/EditAccessoryPanelNode.swift): 294–314, 387–445 — 45 pt панель, close target, текст и thumbnail.
9. [ButtonGroupView](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Calls/CallScreen/Sources/Components/ButtonGroupView.swift): 92–103, 175–178 — активные кнопки 56 pt, gap 36 pt, 52 pt до safe bottom.
10. [PrivateCallScreen](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Calls/CallScreen/Sources/PrivateCallScreen.swift): 803–843, 983–990, 1262 — состав активных контролов, аватар 136 pt, имя 28 pt.
11. [CallControllerButtonsNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramCallsUI/Sources/CallControllerButtonsNode.swift): 157–163 — большие входящие кнопки 72 pt, максимальный gap 115 pt. Не путать с modern active button group.
12. [ChatMessageReplyInfoNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageReplyInfoNode/Sources/ChatMessageReplyInfoNode.swift): 195–197, 524–525, 636–680, 682–698, 735–742 — обычный reply и quote выбирают разные числа строк; thumbnail зависит от высоты текста.
13. [ReplyAccessoryPanelNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ReplyAccessoryPanelNode/Sources/ReplyAccessoryPanelNode.swift): 203, 440–482 — 35 pt thumbnail, 45 pt панель, 44 pt close target, 2 × 35 pt rule.
14. [ReactionButtonListComponent](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/Components/ReactionButtonListComponent/Sources/ReactionButtonListComponent.swift): 719–755, 826–900 — обычная реакция: 30 pt, emoji box 20 pt, side inset 11 pt, gap до счётчика 2 pt, count 11 pt medium.
15. [ChatMessageReactionsFooterContentNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageReactionsFooterContentNode/Sources/ChatMessageReactionsFooterContentNode.swift): 262–286, 438–479, 621–650 — расстояние между кнопками и рядами 6 pt, позиция footer связана с text bubble insets и соседним media.
16. [ChatMessageContactBubbleContentNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift): 20–21, 229–235, 349–362 — avatar 40 pt, gap 7 pt, title/text 14 pt, ширина от контента с минимумом 220 pt до bubble insets.
17. [ChatMessageForwardInfoNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Chat/ChatMessageForwardInfoNode/Sources/ChatMessageForwardInfoNode.swift): 291–293 — базовые 14 pt, regular prefix / medium peer.
18. [ContentOverlayButton](https://github.com/TelegramMessenger/Telegram-iOS/blob/6e370e06d147b091b07903071cb1b8a22152492d/submodules/TelegramUI/Components/Calls/CallScreen/Sources/Components/ContentOverlayButton.swift): 109–110 — label 13 pt regular, ширина до 100 pt, начало за 4 pt после круга; не растягивает сам круг.

## Сопоставление

| Компонент | Telegram, проверенная ветка | Alo до этого прохода | Сейчас / статус |
| --- | --- | --- | --- |
| Капсула даты | 22 pt; 6 pt горизонтальный inset; 13 pt medium, до 18 pt | размеры уже совпадали, но floating использовал яркую поверхность общего glass-control | отдельный тихий service material, без декоративной кромки общего контрола |
| Секция даты | 34 pt | 22 + 6 pt padding и произвольный межстрочный gap | секция 34 pt |
| Дата при scroll | sticky в пределах дня, рядом с границей истории | неподвижный overlay, выбор по порогу `max(108, chrome + 44)` | natural/sticky handoff и push-off следующим днём; anchor под живым chrome/player |
| Видимость даты | drag/deceleration; после idle задержка 0.3 s; alpha 0.3/0.4 s | таймер 1 s перезапускался при измерении строк; alpha 0.15 s | phase-based; 0.3 s задержка, 0.3/0.4 s alpha; Reduced Motion |
| Камера записи кружка | на обычном телефоне `min(404, minSide − 24)`; при стороне 320 — 216 | `min(300, width − 64, height − 220)` | размер по референсу; дополнительное ограничение, чтобы не перекрыть composer/keyboard |
| Вход камеры | от нижней области, scale 0.3 → 1; spring 0.5 s, damping 0.8 | scale 0.82 от bottomTrailing, spring 0.38 | траектория снизу, scale 0.3 → 1, spring 0.5/0.8; без движения при Reduced Motion |
| Curtain камеры | dark legacy ветки используют black 0.4 или 0.6 и разные blur paths | общий Alo modal backdrop: black 0.32 + blur | **не менялся**; одинаковым затемнением Telegram не объявляется |
| Кольцо записи | диаметр камеры − 8 pt | кольцо снаружи: padding −4 | inset 4; спокойный белый цвет |
| Orb записи | 110 pt | уже 110 pt | сохранён |
| Drag cancel / lock | 150 / 110 pt | уже 150 / 110; индикатор lock делился на 105 | индикатор и порог используют одни 110 pt |
| Одиночное фото | compact предел 300 × 380; минимум 170 × 74; aspect fitting | фиксированные 220 pt высоты, ширина до 340 | пропорции и compact limits; portrait может быть уже landscape |
| Одиночное видео | max height 250 landscape / 360 portrait | те же 220 pt | лимиты 250/360 по ориентации |
| Media dimensions | часть данных медиа, до показа | отсутствовали в локальном черновике | чтение image header без полного decode; async video track + transform; encrypted metadata и outbox сохраняют размеры |
| Редактирование caption | apply/checkmark, можно добавлять/удалять подпись медиа | фото без подписи нельзя редактировать; пустой caption включал микрофон; кнопка send-arrow | добавление/удаление caption, checkmark, очищение конфликтующего Reply; вложение сохраняется |
| Edit accessory | 45 pt; close 44; thumbnail 35; title 15 / preview 14 | 45 / 44; текст 15; thumbnail нет | функциональные баги исправлены; thumbnail и соединённая с composer геометрия ещё отличаются |
| Активный звонок | круги 56; gap 36; avatar 136; имя 28 regular | размер кругов/аватара/имени совпадал; имя semibold, слоты равномерно растягивались по ширине | фиксированный gap 36, имя regular; gap уменьшается только на тесном экране |
| Входящий звонок | крупные 72 pt, gap до 115 | 72 / 115 | совпадает с проверенной CallController-веткой, не переделывался |
| Нижний отступ активных call-кнопок | circle bottom за 52 pt до safe bottom; notice на 16 pt выше круга | HStack высотой 84 и padding 36 давал 60 pt | padding 28 даёт 52 pt; проверено UI-тестом на SE и Pro для первого контрола; notice привязан к тем же константам |
| Кружок в сообщении | compact 212 × 212, regular 240 × 240 | phone 212 × 212 | compact совпадает; regular/tablet ещё не проверен |
| Фото в альбоме / mosaic | отдельный MosaicLayout, зависит от пропорций всех элементов | фиксированные схемы 2/3/4 элементов | **ещё отличается**, этот проход не заменяет mosaic engine |
| Медиа/редактор поста в ленте | канал — message bubble/editor; stories — отдельный editor | отдельный wall/feed редактор, высоты 260/230/270, edit-post API в iOS не найден | **ещё отличается**, не объявляется исправленным |
| Reply внутри сообщения | обычный: title/text 14 pt, по строке; quote — 2 строки title и 5/50 текста; thumbnail по line height | 14 pt, по строке, минимум 44 pt; без thumbnail и отдельного quote layout | обычный текст частично совпадает, media reply и расширенная цитата ещё отличаются |
| Reply над composer | 45 pt, thumbnail 35, rule 2 × 35, close 44 | 45 / 2 × 35 / 44, без thumbnail | размеры основных элементов совпадают; preview медиа ещё отсутствует |
| Forward attribution | 14 pt; regular prefix / medium peer | 13 pt bold либо semibold в зависимости от bubble | **ещё отличается**, нужно одно общее представление вместо нескольких веток |
| Reaction chip | обычная: 30 pt, emoji box 20, count 11 medium, side inset 11, внутренний gap 2 | 30 pt, emoji font 16, count 12 semibold, inset 8, gap 4; touch row 44 | высота совпадает, остальная геометрия и peers/avatars ещё отличаются |
| Reaction wrapping/footer | ряды и кнопки через 6 pt; inset от text bubble, отдельная поправка возле media | 6 pt между hit boxes; rowSpacing −8 компенсирует 44 pt touch row до 36 pt визуального шага | расстояние рядов частично совпадает; горизонтальный inset надо считать от визуальной капсулы, не только от touch box |
| Contact card | avatar 40, gap 7, title/text 14; адаптивная ширина | avatar 40, gap 7, body 17 / subheadline 15; min 220 / max 286 | аватар/gap совпадают, шрифты и набор действий отличаются |
| Text bubble insets | compact: 11 / 11 horizontal; top 6 + pixel / bottom 6 − pixel | simple text: leading 11 / trailing 10; top/bottom 8 | **ещё отличается**, вертикальные insets в сумме больше на 4 pt |
| Text bubble width floor / edge | compact min bubble 40 × 35; edgeInset 3; итоговая ширина зависит также от текста и status | content floor 84 до padding, outer history inset 14, opposite inset 40 | политики различаются; нельзя считать все сообщения одинакового размера или заменить floor без status/selection QA |

## Внесённые изменения и выявленные дефекты

### Высокий приоритет: дата была отдельной несвязанной плашкой — исправлено

Отдельный `AloChatDateHeaderController` наблюдается только представлениями дат.
Геометрия не публикуется в корень всего чата на каждом кадре. Индекс дня
вычисляется в memoized history snapshot, без повторного разбора timestamp при
scroll. Учтён перенос истории над клавиатурой; floating плашка маскируется ниже
верхней панели. Natural header и pinned header не рисуют один день дважды.

### Высокий приоритет: фиксированная высота фото/видео — исправлено для одиночного медиа с размерами

Для старых сообщений без размеров есть стабильный fallback 4:3. Обновление
размеров по загрузке изображения в списке не применяется: оно вызвало бы
прыжки высоты при scroll. Для новых файлов orientation учитывается до
создания bubble; dimensions идут внутрь существующих encrypted metadata.
Размеры survive `withDuration`, waveform replacement и восстановление outbox.
Геометрия изображения жёстко ограничена ячейкой: accessibility/touch-область
не должна выходить за её реально видимый crop.

### Высокий приоритет: пустая подпись включала запись — исправлено

В edit mode send state учитывает исходное media, а не новый `localAttachments`.
Save сохраняет существующие attachments через существующую edit-operation.
Тестовый аккаунт из offline UI fixture не отправляет edit в настоящий API.
Это Debug-only изоляция, обычная отправка изменений не отключена.

### Дополнительный дефект: переход к последним сообщениям

После увеличения секций дней тест обнаружил прежнюю проблему оценки
LazyVStack: новые строки оставались ниже клавиатуры. Переход материализует
последний message ID и затем выравнивает настоящий bottom anchor с composer
inset. Удалена вторая, неиспользуемая привязка `.scrollPosition`: она конфликтовала
со `ScrollViewReader`. Отложенное выравнивание отменяется при пользовательском
drag, смене запроса и закрытии. Проверка последнего сообщения над composer
не ослаблена. Повторение выявило, что этого недостаточно: footer может ещё не
быть создан `LazyVStack`. Нижний якорь вынесен из ленивой части списка;
на SE выполнены три успешных повтора подряд с открытой клавиатурой. Это
проверка конкретного сценария, не доказательство отсутствия всех scroll-багов.

## Проверка

Итоговый код проверен на Xcode 26.2 / Swift 6.2.3, iOS Simulator 26.2. Проект
остаётся в своём Swift language mode; миграция на новую версию языка не делалась.

- **iPhone 17 Pro, 402 × 874 pt:** 55 тестов / 67 запусков с параметрами,
  0 ошибок и 0 пропущенных. Проверены geometry/date, history projection,
  media performance, capture/export и encrypted draft; UI — aspect ratio,
  caption edit, date idle/Reduced Motion, запись/flip/lock, повторные переносы
  плавающего кружка, отменённый back swipe и back во время voice/circle playback,
  call controls, переход к новым сообщениям с открытой клавиатурой.
  Result: `Test-AloiOS-2026.10.10_19-31-48-+0300.xcresult`.
- **iPhone SE (3rd generation), 375 × 667 pt:** исправленный переход к новым
  сообщениям с клавиатурой повторён три раза подряд, все три прошли. Проверены
  совпадение оси кнопки вниз и record/send, два новых сообщения выше composer,
  очистка счётчика и сохранение черновика.
  Result: `Test-AloiOS-2026.10.10_19-28-24-+0300.xcresult`.
- Размеры фото, edit accessory, date idle/Reduced Motion, circle capture и
  call controls также прошли UI-проверки на SE. В том промежуточном прогоне
  обнаружен scroll-дефект; после выноса footer выполнены повторы выше.
- `git diff --check` и Swift syntax parse изменённых view-файлов — без ошибок.
  После финального прогона изменены только форматирование и комментарии.

Тесты используют изолированные Debug fixtures, не отправляют изменения
с реального аккаунта и не доказывают работоспособность сервера или живого звонка.
Результаты Xcode могут автоматически вытесняться следующими запусками;
снимки экспортированы в `Design/QA-telegram/2026-10-10`.

Снимки проверены визуально: [portrait media](/Users/mikhail/AloiOS/Design/QA-telegram/2026-10-10/pro-final-geometry/413EC6A0-6F10-4B38-9643-D40D54C65F3F.png),
[caption edit](/Users/mikhail/AloiOS/Design/QA-telegram/2026-10-10/se-final-geometry/B92B9428-CE6E-48BB-83E3-BD5E1A70BFF5.png),
[новые сообщения над клавиатурой](/Users/mikhail/AloiOS/Design/QA-telegram/2026-10-10/se-navigation-repeat-passed/F6C75FAB-C045-4812-BBBA-742093495DDD.png),
[recording fixture](/Users/mikhail/AloiOS/Design/QA-telegram/2026-10-10/se-verified-recording/2CED16A8-38E5-461C-BA1E-D452752F18DD.png),
[call fixture](/Users/mikhail/AloiOS/Design/QA-telegram/2026-10-10/se-verified-call/3F418FBD-5B55-4E74-B311-7D07964BCC35.png).
Чёрная камера в recording/call fixture — отсутствие реальной камеры симулятора,
а не проверка фронтальной камеры телефона. На call fixture длинные подписи
сжимаются сильнее коротких и немного влияют на вертикальную геометрию остальных
контролов: один этот тест нельзя считать проверкой точного положения всех кругов.

Пока не заявляются: все размеры клиента, performance/FPS на физическом iPhone,
визуальное совпадение на iOS 18, реальный двухсторонний видеозвонок, полный
редактор wall post, mosaic альбомов и полное совпадение камер/анимаций Telegram.
Новая сборка для физического iPhone в этом проходе не выполнялась; к концу
проверки на Mac оставалось меньше 1 ГБ. Никакие пользовательские файлы,
DerivedData или данные симуляторов для освобождения места не удалялись.

## Следующий измеримый проход

1. Mosaic фото/видео и preview выбранных вложений вместо фиксированных высот.
2. Edit media preview 35 pt, сохранение исходного draft при отмене редактирования.
3. Посты ленты: проверенный update endpoint и полноценный edit, не псевдокнопка.
4. Calls: label width (сейчас 56 вместо reference constraint 100), переключение renderer и gestures на реальных
   двух телефонах; iOS 18 material QA отдельно от Debug fallback на iOS 26.
5. Reply/forward, reaction/status footer, polls/contact — перечисленные выше различия и
   проверки длинного текста, выделения, Accessibility text sizes.
