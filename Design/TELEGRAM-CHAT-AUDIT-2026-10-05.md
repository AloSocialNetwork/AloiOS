# Чат и звонки: продолжение сверки 5 октября

Нативный SwiftUI/UIKit-клиент Alo. Цель — привычная геометрия и взаимодействие
Telegram без переноса его private API, транспорта и ассетов. Применены Apple
Design, Animate, Write Swift и UI/UX Pro Max. В установленном Apple Design
отсутствуют отдельные HIG-справочники; полный HIG-аудит не заявляется.

## Прочитанные исходники

Референс закреплён на `6ad963e5b62d354da79040f388ae2b9132fb17b8`, а не смешан
с произвольными версиями клиента:

- [InteractiveTransitionGestureRecognizer](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/Display/Source/InteractiveTransitionGestureRecognizer.swift): распознавание оси и исключение горизонтальных контролов.
- [NavigationTransitionCoordinator](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/Display/Source/NavigationTransitionCoordinator.swift): отмена 100 ms, завершение по расстоянию/скорости 50–200 ms.
- [NavigationContainer](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/Display/Source/Navigation/NavigationContainer.swift): переход ведётся native translation; Telegram завершает его при progress > 0.2 / velocity > 1000. В Alo оставлена защита от случайного закрытия: минимум 24 pt, отмена при движении обратно, progress 0.30 / projection 0.46 / velocity 980. С правого края порог масштабируется к доступному ходу пальца. Это намеренное отличие, не буквальная копия.
- [PrivateCallScreen](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/Calls/CallScreen/Sources/PrivateCallScreen.swift): перестановка видеоповерхностей за 250 ms.
- [VideoContainerView](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/Calls/CallScreen/Sources/Components/VideoContainerView.swift): непрерывность источника видео, сохранение геометрии, замена источника и обработка движения.
- [ChatMessageReplyInfoNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/Chat/ChatMessageReplyInfoNode/Sources/ChatMessageReplyInfoNode.swift): имя/предпросмотр 14 pt и автор пересланного сообщения.
- [ChatMessageContactBubbleContentNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/Chat/ChatMessageContactBubbleContentNode/Sources/ChatMessageContactBubbleContentNode.swift): аватар 40 pt, промежуток колонки 7 pt.
- [TGModernConversationInputMicButton](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/LegacyComponents/Sources/TGModernConversationInputMicButton.m): отдельные пороги движения и отпускания записи.
- [ChatMessagePollBubbleContentNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/Chat/ChatMessagePollBubbleContentNode/Sources/ChatMessagePollBubbleContentNode.swift): процент в колонке 42 pt, шрифты bold 14.5 / 12.5 для 100%, начало текста 50 pt.

## Изменения

- Свайп: совместное распознавание только с настоящим `UIScrollView.panGestureRecognizer`,
  а не любым дочерним scrubber/tap внутри ScrollView. Пустая подложка и сообщения
  используют один recognizer; назад только вправо, намерение определяется до
  захвата. Нижняя навигация остаётся смонтированной за чатом.
- Вместо тени всего дерева чата при каждом кадре — отдельный градиент шириной
  18 pt у левого края. Это устранение лишней отрисовки по коду, не измеренный FPS.
- В звонке видеопредставления имеют стабильную идентичность local/remote,
  независимо от роли primary/preview. Перестановка меняет геометрию за 250 ms,
  не переподключает два новых Metal renderer. Таймер звонка не перезапускает
  неизменившийся transform/alpha renderer.
- Кружок при записи: публичный тёмный UIKit blur маскирует смену камеры;
  зеркало меняется атомарно, повторный flip блокируется до завершения операции.
  Новый session, копия кадров и snapshot камеры для эффекта не создаются.
- Стекло: чёрная tint 0.36 для контролов / 0.48 для панелей вместо 0.32/0.42.
  На iOS 18 сохраняются живой UIKit material, световой край и тень;
  Reduce Transparency/Increase Contrast используют непрозрачный вариант.
- Контакт: аватар 40 pt, промежуток 7 pt, системные body/subheadline,
  убрана вторая вложенная плашка и дублирующий значок контакта. Явный
  contentShape включает внутренние отступы в область нажатия.
- Ответы: сохраняются ограниченные две строки цитаты и плашка composer
  45 pt с крестиком 44 pt; добавлены проверки ответа на фото и голосовое,
  чтобы техническое имя вложения не становилось текстом цитаты. Фото/видео,
  контакт и геопозиция имеют понятные подписи вместо общего «Вложение».
- Reduce Motion: возврат к звонку из компактной панели, открытие карточки
  безопасности и замена значков больше не запускают лишние перемещения.
- Опрос: визуальная проверка выявила обрезанное «100%», несмотря на корректный
  AX-label. Колонка расширена 28 → 42 pt, начало текста/полоски 38 → 50 pt,
  проценты 14.5/12.5 bold без ellipsis. Метрики поддерживают Dynamic Type;
  повреждённые значения результата ограничены 0...100%. Тест проверяет
  ширину реальных глифов, не только наличие accessibility-строки.

Базовые размеры предыдущего прохода сохранены: кружок 212 pt / расширенный
до 404 pt; видимая кнопка composer 40 pt с касанием 44 pt; кнопки звонка
56 pt и аватар 136 pt. Запись: удержание 190 ms, движения cancel/lock
150/110 pt, отпускание 100/60 pt или скорость 400 pt/s.

## Проверка и пределы

### Стрелка вниз, отправка медиа и отступы реакций

Reference: [ChatHistoryNavigationButtonNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Sources/ChatHistoryNavigationButtonNode.swift),
[ReactionButtonListComponent](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/Components/ReactionButtonListComponent/Sources/ReactionButtonListComponent.swift),
[ChatMessageReactionsFooterContentNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/Chat/ChatMessageReactionsFooterContentNode/Sources/ChatMessageReactionsFooterContentNode.swift)
и [ChatMessageItemCommon](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/Chat/ChatMessageItemCommon/Sources/ChatMessageItemCommon.swift).

- Кнопка вниз: видимый круг 40 pt, касание 44 pt, счётчик 20 pt с текстом
  13 pt и смещением -7 pt. Находится над composer, учитывает клавиатуру,
  не появляется над последними сообщениями. Геометрия ScrollView вместо
  координат выгружаемого LazyVStack bottom anchor. Проекция в две Bool не
  вызывает обновление всего чата на каждый пиксель прокрутки.
- После скриншота со смещением: trailing был 12 pt у стрелки и 16 pt у
  composer, поэтому оси отличались на 4 pt. Оба используют общий
  `AloChatMetrics.inset` 16 pt при одинаковой ширине касания 44 pt.
  UI-тест сравнивает реальные midX до/после открытия клавиатуры и смены
  микрофона на отправку, а не только наличие кнопки.
- Проверка keyboard capture нашла исчезающий badge: lazy anchor и полный
  viewport могли считать сообщения, закрытые клавиатурой, достигнутыми.
  Сброс счётчика теперь только по scroll geometry; фактически закрытая
  клавиатурой часть вычитается из viewport, если история не поднялась вместе
  с composer. В UI-тест добавлено сохранение числа 2 после открытия keyboard.
- Нажатие при открытой клавиатуре включает следование истории вверх и
  публичный iOS 18+ `ScrollPosition.scrollTo(edge: .bottom)`. ID anchor в
  LazyVStack мог закончить анимацию на оценочной позиции, закрытой composer;
  кнопка теперь не зависит от существования этого anchor. Отдельный
  `AloChatHistoryNavigationUITests` проверяет видимость последнего текста
  выше input, исчезновение стрелки и неизменный черновик после перехода.
- Счётчик учитывает реальные новые входящие message IDs, полученные при
  чтении старой истории; повторы refresh, собственные ACK, отложенные и
  удалённые сообщения не увеличивают число. Для темы учитывается доступный
  серверный unreadCount. В существующем direct/non-forum API чтение всей
  переписки отмечается при GET; полноценный межсессионный read-through
  cursor требует отдельного изменения серверного контракта, здесь не
  подменяется выдуманным числом.
- Animate/Apple Design: короткое появление стрелки через opacity/offset,
  существующий release token 160 ms; Reduced Motion исключает перемещение.
  Нет нового animator/timer, эффекта blur на каждый кадр или layout spring.
- Реакции: видимая высота 30 вместо 32 pt, визуальный шаг строк 36 pt
  (30 + 6), касание остаётся 44 pt. Вместо внешних 8–10 pt под touch target
  оставлен только его внутренний 7 pt запас; leading для текста/подписи/
  пересылки 11 pt. Telegram имеет дополнительные 6 pt со стороны хвоста
  входящего bubble; у Alo нет такого хвоста. Шрифт emoji/counter сохранён
  адаптированным для компактных экранов, весь renderer Telegram не перенесён.
- Блокировки обнаружены в коде: шифрование/копирование outbox вложений
  синхронно на MainActor; base64 больших фото в optimistic model; повторный
  UIImage/base64 decode внутри body. Теперь snapshots файлов и очереди
  последовательно сохраняются на utility queue. Сетевая отправка ждёт
  durable receipt; UI/очистка composer — нет. Ошибка сохранения оставляет
  сообщение и явный retry. Очистка/logout ставятся в ту же очередь после
  snapshots и не могут воскресить данные старого аккаунта.
- Photos/file import и data fallback возвращают файл с ciphertext и private
  playback URL. Фото в composer/галерее имеют отдельный асинхронный preview
  максимум 512 px, fullscreen — 2048 px; нет потери превью после отказа от
  inline Data. Декодирование старых inline сообщений тоже вынесено из body.
- Проверки не отправляют контент в реальный аккаунт: URLProtocol имитирует
  upload/ACK и отказ GET истории. После ACK медиа остаётся в активном чате,
  pending очищается без перезапуска и повторной отправки. Большой outbox
  fixture проверяет быстрый enqueue, порядок snapshots и восстановление.

Проверки этого изменения:

- Финальный прогон галереи, стрелки и channel-media: 8 тестов на двух
  симуляторах iPhone 17 Pro / SE 375 pt, 16 запусков, 0 failures.
  `/private/tmp/alo-20261005-navigation-gallery-final.xcresult`.
  Скриншоты выбранного file-backed фото, channel reactions и стрелки с
  двумя входящими просмотрены вручную.
- Отправка/очередь: 16 тестов / 17 запусков (параметры фото и видео),
  0 failures. Включает существующие 10 sending regression, новый worker
  outbox, счётчик по IDs и явный отказ durable save без HTTP upload.
  `/private/tmp/alo-20261005-media-delivery-final.xcresult`.
- Дополнительная проверка после очистки upload: 2 теста / 3 запуска,
  0 failures. Для фото/видео читается сохранённый private payload после ACK,
  отказа обновления истории и завершения очереди cleanup; медиа доступно
  без перезапуска/повторного скачивания.
  `/private/tmp/alo-20261005-media-playback-final.xcresult`.
- Финальная навигация: 6 тестов на двух симуляторах iPhone 17 Pro / SE
  375 pt, 12 запусков, 0 failures.
  `/private/tmp/alo-20261005-navigation-scroll-position.xcresult`.
  Проверены одинаковая ось стрелки и record/send, сохранение badge при
  открытии клавиатуры, видимость последнего входящего выше composer и
  сохранение текста черновика. Скриншоты обоих размеров просмотрены вручную.
- Дополнительный UI regression после перехода на ScrollPosition: свайп
  назад во время playback, расстояние строк реакций/метаданных, footer
  комментариев канала и выбор фото в галерее — 4 теста, 0 failures.
  `/private/tmp/alo-20261005-navigation-last-regression.xcresult`.
- Первый UI-прогон нашёл проблему lazy bottom anchor; он заменён на scroll
  geometry. Промежуточный compact прогон — 27/28: оставшийся тест ожидал
  прежние 12 pt вместо новых 11 pt у media caption. Ожидание приведено к
  новой метрике и дополнено проверкой leading реакции; повтор на обоих
  размерах прошёл в `navigation-gallery-final`. Остальные compact regression
  (реакции, media swipe и scroll smoke) прошли в промежуточном прогоне.
- Промежуточные keyboard UI-прогоны выявили ещё два дефекта: ложное
  достижение закрытой истории и остановку ID-based scroll под composer.
  Финальные проверки выше выполнены после исправления обоих, а не только
  после корректировки горизонтального отступа.
- Подписанная arm64 Debug-сборка и `codesign --verify --deep --strict`
  успешны. `/private/tmp/alo-20261005-media-navigation-device-final.xcresult`.
  Четыре прежних предупреждения AVAssetExportSession/ориентаций остались.
  Это не установка/проверка задержек на физическом iPhone и не замер FPS;
  реальный сервер/аккаунт не использовался в send tests.
- После финального ScrollPosition/keyboard исправления подписанная
  arm64 Debug-сборка повторена: 0 errors, успешный codesign verification.
  `/private/tmp/alo-20261005-history-final-device.xcresult`.
  Инкрементальный прогон сообщил одно существующее предупреждение об
  ориентациях; это не означает исправление ранее известных deprecations.

### Дополнительный проход: чёрное затемнение и размытие краёв

**Промежуточный вариант от 5 октября, не актуальная композиция.** При нём
ошибочно учтена только обычная, а не inverted-pattern ветка Telegram.
Актуальная коррекция: [CHAT-EDGE-DIMMING-2026-10-06.md](CHAT-EDGE-DIMMING-2026-10-06.md).

**Коррекция после скриншота с чрезмерными чёрными полосами:** прежнее
описание ниже фиксирует промежуточный вариант, не актуальный renderer.
Повторное чтение `WallpaperEdgeEffectNodeImpl` показало ошибку интерпретации:
`alpha: 0.75` относится к восстановленному wallpaper, а не к чёрному scrim.
Сочетание `.dark` blur и 75% чёрного действительно давало чрезмерные полосы.

- `AloChatEdgeBackdrop` теперь рисует собственные обои Alo с тем же размером
  canvas и вертикальным window-origin. Маска остаётся 80 pt сверху / 60 pt
  снизу, с расширениями 34 / 20 pt. Это уменьшение видимого затемнения, а не
  уменьшение safe area или смещение кнопок.
- Сверху публичный UIKit backdrop blur **за восстановленными обоями**,
  чтобы приглушать текст сообщений при скролле; снизу blur отсутствует,
  как у нижнего wallpaper edge в reference. Чёрного scrim на scroll edges
  больше нет. Приватный variable backdrop blur Telegram не перенесён:
  его радиус/renderer не заявляются идентичными публичному UIKit blur.
- Нижний слой продолжен за закруглённые углы клавиатуры. Повторная отрисовка
  использует window-origin, а не новый градиент в маленьком прямоугольнике.
- Полноэкранный scrim контекстного меню/записи не менялся. Его helper больше
  не принимает scroll edge, чтобы прежняя ошибка композиции не вернулась.
- Apple Design: разделены функциональные стеклянные контролы и фоновые
  edge-слои. Reduce Transparency / Increase Contrast убирают blur и делают
  восстановление wallpaper непрозрачным; слои не принимают касания.
- Добавлены pixel assertions на ярком ocean-fixture у верхнего/нижнего края:
  прежние проверки только размеров/касания пропускали чёрные полосы.
  На 402 pt первоначальный прогон: 22 теста / 30 запусков, 0 failures;
  `/private/tmp/alo-20261005-wallpaper-edges-large.xcresult`.
  На 375 pt: 3 UI-теста, 0 failures, включая новые pixel checks и Reduce
  Transparency; `/private/tmp/alo-20261005-wallpaper-edges-compact.xcresult`.
  Финальный вариант с публичным верхним backdrop blur: 23 теста / 62 запуска
  на обоих размерах, 0 failures, в том числе pixel assertions, клавиатура,
  панели ГС/кружка и Reduce Transparency.
  `/private/tmp/alo-20261005-wallpaper-edges-blur-final.xcresult`.
  Просмотренные финальные скрины: `Design/Verification/2026-10-05-edges/`.
  Оба на iOS 26.2, включая принудительную ветку legacy glass. Это **не**
  проверка на физическом устройстве с iOS 18 и не измерение FPS.

Сверены [ChatControllerNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Sources/ChatControllerNode.swift),
[WallpaperEdgeEffectNodeImpl](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/WallpaperBackgroundNode/Sources/WallpaperEdgeEffectNodeImpl.swift)
и [EdgeEffect](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/EdgeEffect/Sources/EdgeEffect.swift).

- Удалён `.regularMaterial` из верхнего/нижнего края и полноэкранного
  затемнения меню/записи: он добавлял адаптивную серую заливку. Вместо неё —
  публичный тёмный UIKit blur и отдельный слой именно `UIColor.black`.
- Маска: компактная выборка нормализованной кривой reference. Затухание
  фиксировано на 80 pt сверху / 60 pt снизу, расширения 34 / 20 pt и минимум
  высоты 100 pt. Safe area входит в геометрию. Высокая панель плеера не
  растягивает затухание и не уменьшает эффект за заголовком.
- В обычном чате два ограниченных по высоте backdrop. При клавиатуре нижний
  переносится за composer и продолжается под закруглённые углы клавиатуры,
  без стыка двух разных материалов. Цвет затемнения — чёрный, opacity 0.75.
- UIKit view/effect сохраняют идентичность. Одинаковая конфигурация не меняет
  effect; нет screenshot истории, CPU-обработки кадров, таймера или обновления
  маски при каждом scroll offset. Это проверка структуры, не измеренный FPS.
- Apple Design повлиял на разделение декоративного edge и интерактивных
  контролов; Reduce Transparency / Increase Contrast отключают live blur,
  декоративные слои не захватывают касания и не входят в VoiceOver.
- Это не буквальный перенос всего renderer Telegram: у него wallpaper clone,
  private variable blur сверху и `blur: false` у нижнего wallpaper edge.
  Здесь публичный live blur под чёрной маской, в том числе внизу для усиления
  размытия по запросу пользователя; материалы контролов остаются отдельными. Не заявляется
  pixel-perfect равенство private effect.

- iPhone 17 Pro, 26.2: три UI-проверки края, клавиатуры, long press и доступности
  прошли. Первый прогон также нашёл слишком строгое равенство Float-значения
  `UIView.alpha == 0.32` в новом unit-тесте; исправлен допуск сравнения,
  не цвет/opacity renderer. `/private/tmp/alo-chat-20261005-edges-large-fix.xcresult`.
- 375 pt: 24 теста / 32 запуска с параметрами, 0 failures, включая тот же
  новый unit-тест и свайп. `/private/tmp/alo-chat-20261005-edges-compact.xcresult`.
- Большой экран, дополнительный прогон: 23 теста / 31 запуск, 0 failures,
  панели ГС/кружка, перенос мини-кружка и smoke performance mixed media.
  `/private/tmp/alo-chat-20261005-edges-player.xcresult`.
- Финальная проверка геометрии header/аватарки и клавиатуры повторена на
  обоих размерах, 2/2 запуска без ошибок. Native glass и принудительный
  legacy проверены внутри каждого запуска.
  `/private/tmp/alo-chat-20261005-edges-header-final.xcresult`.
- Скриншоты edge, клавиатуры, меню и верхних плееров просмотрены вручную.
  Smoke на симуляторе: три итерации scroll, physical memory около 85.2 MB,
  peak 85.8–86.1 MB, CPU 0.305–0.320 s на сценарий. Нет baseline старой версии:
  это не подтверждение ускорения, GPU frame pacing или отсутствия лагов
  на физическом iOS 18.
- Реальный iPhone 18.6.2 виден как paired, но developer services / tunnel
  недоступны; forced legacy на 26.2 остаётся проверкой fallback, не real iOS 18.
- Подписанная arm64 Debug-сборка после изменений успешна; `codesign --verify`
  без ошибок. `/private/tmp/alo-chat-20261005-edges-signed.xcresult`.
  На физический телефон не установлена. Предупреждение об ориентациях остаётся.

### Результаты предыдущего прохода

- Первый большой проход: 25 тестов / 29 запусков с параметрами без ошибок,
  iPhone 17 Pro, iOS 26.2. `/private/tmp/alo-chat-20261005-transitions.xcresult`.
- Компактный проход: 28 тестов / 32 запуска с параметрами; 27 тестов прошли,
  один нашёл AX-область контакта 41.5 pt. После contentShape обе проверки
  контакта/ответов повторены без ошибок: 2/2,
  `/private/tmp/alo-chat-20261005-compact-fix.xcresult`. Это точечный повтор,
  не утверждение о повторном полном прогоне.
- Финальный большой проход: 9/9 UI-тестов без ошибок — мини-кружок,
  прокрутка во время проигрывания, свайп поверх разных типов сообщений,
  ответы/контакт, реакции и голосование.
  `/private/tmp/alo-chat-20261005-large-final.xcresult`.
- После исправления процентов и Reduce Motion: 3/3 UI-теста без ошибок —
  голосование, увеличенный текст composer опроса и повторные перестановки
  primary/preview видео. Скрин результата проверен: «100%» больше не обрезается.
  `/private/tmp/alo-chat-20261005-final-polish.xcresult`.
- Подписанная Debug arm64-сборка для физического iOS: success, 0 errors.
  `/private/tmp/alo-chat-20261005-device-signed.xcresult`;
  подпись Apple Development проверена `codesign`, команда использовала
  штатное `-allowProvisioningUpdates` существующей команды проекта.
  Установка не выполнялась: после сборки CoreDevice больше не обнаруживает
  ранее подключённый iPhone. 4 предупреждения остаются: три старых API
  AVAssetExportSession и поддержка ориентаций; success не означает их устранение.
- Заключительный проход на 375 pt: 29 тестов / 35 запусков с параметрами,
  0 failures. Покрывает геометрию/намерение свайпа, один player при переносе
  кружка, отсутствие удержания закрытых видеоповерхностей, опрос и полный
  процент при Dynamic Type accessibility3.
  `/private/tmp/alo-chat-20261005-last-regression.xcresult`.
- Офлайн-фикстуры не отправляют сообщения и не создают настоящие звонки.
  Чёрная камера в симуляторе не подтверждает работу физической камеры.
- Проверка материала iOS 18 принудительным fallback на iOS 26.2 не заменяет
  реальный iOS 18. iPhone 16 Pro на 18.6.2 кратко подключился; CoreDevice
  сообщает, что требуется passcode. Запуск тестов завершился таймаутом
  подготовки destination, не ошибкой компиляции. Установка и проверка этой
  версии на телефоне не подтверждены; запрос разблокировки отправлен.
- История пока `LazyVStack`, не Telegram ListView. Нет полного gallery
  shared-element/zoom/dismiss и общего voice playlist coordinator.
- Перестановка видеоповерхностей звонка сближена по механике, но размеры
  preview и весь lifecycle/capture звонка не объявляются совпадающими с Telegram.
- Реальная непрерывность переключения камеры при записи, задержка capture,
  удалённый видеопоток, шифрование/upload и frame pacing требуют проверки
  физического устройства. Не объявляются исправленными по UI-тестам.
- Не заявляется совпадение всех размеров/функций Telegram или полный аудит
  остальных вкладок. Данные аккаунта и кэши не сбрасывались.

## Меню и предпросмотр: исходники и видео IMG_4998

Дополнительно прочитаны исходники официального Telegram iOS на том же
фиксированном commit, а не только рассмотрены кадры видео:

- [ContextActionNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/ContextControllerImpl/Sources/ContextActionNode.swift):
  боковой отступ 16 pt, вертикальный 12 pt, отдельный слот иконки.
- [ContextActionsContainerNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/ContextControllerImpl/Sources/ContextActionsContainerNode.swift):
  базовая ширина списка действий 250 pt. В Telegram она может увеличиваться
  под содержимое; в Alo длинный текст переносится, а список прокручивается.
- [ContextControllerExtractedPresentationNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/ContextControllerImpl/Sources/ContextControllerExtractedPresentationNode.swift):
  размещение относительно выбранного элемента, преобразование координат
  и spring появления 0.42 s. Alo использует SwiftUI spring response 0.42,
  dampingFraction 1, а не переносит внутренний CALayer/portal стек.
- [ReactionContextNode](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/ReactionSelectionNode/Sources/ReactionContextNode.swift):
  компактная панель высотой 46 pt, адаптивное количество слотов и раскрытие.

Из пользовательского IMG_4998 просмотрены 12 кадров за 23.84 s. Видео
демонстрирует предпросмотр чата из списка; меню отдельного сообщения и
расширенные реакции сверяются с приложенными скриншотами и исходниками.

Изменения текущего прохода:

- Убрана большая карточка с аватаркой из заголовка предпросмотра: теперь
  компактный центральный овал. Меню ниже выровнено к правому краю, ширина
  250 pt. Короткое нажатие продолжает открывать переписку.
- Frame строки читается один раз при активации. Нет публикации словаря
  геометрии всех строк на каждом кадре скролла. Предпросмотр поднимается от
  источника; фон отдельно покрывает весь экран.
- Исправлено преобразование window frame выбранного сообщения в локальную
  систему координат меню. Меню, сообщение и реакции держат общий край.
- Добавлены реальные дата/время, порядок действий и отступы; разрешения
  редактирования, пересылки и закрытия опроса сохранены. Действие выполняется
  после анимированного закрытия, повторные нажатия во время выхода блокируются.
- Расширенная панель реакций скрывает список действий, содержит поиск
  поддерживаемых Unicode emoji. Удержание показывает существующий count и
  текущего пользователя только если reactedByMe=true.
- Внешняя плашка соединения скрыта на время предпросмотра. Неизвестное
  mute-состояние не представлено вечным spinner/неработающим действием.
- Один ограниченный UIKit blur и чёрная подложка вместо тяжёлого glass-host
  в каждом элементе меню. Apple Design повлиял на отдельные 44 pt hit targets,
  Reduced Motion / Reduce Transparency и немедленный feedback строки.

Ограничения: API AloMessageReaction содержит только emoji/count/reactedByMe.
Список всех реагировавших, время реакции и кастомные emoji-паки не выдуманы
и не реализованы. В списке чатов не добавлены фиктивные Pin/Archive/Mark Unread
без серверного контракта. Нативное извлечение исходного view в portal и
скролл длинного выбранного сообщения один-в-один с Telegram не заявляются.
Реальный iOS 18 и физическое устройство этим проходом ещё не проверены.

Дополнительные проверки взаимодействия выявили два дефекта и привели к
исправлениям: общий AX identifier панели перекрывал identifier поля поиска;
удержание emoji одновременно доставляло стандартное действие Button на
touch-up. Панель получила собственный accessibility container. Реакции
используют UIKit UIButton с парой UILongPress / UITap, где tap явно требует
отказа hold. Для accessibility есть стандартная активация и отдельное действие
просмотра. Попытки разделить эти действия SwiftUI exclusive gesture / latch
не прошли проверку двух сценариев и не входят в итоговую реализацию.

Итоговая проверка после перехода к UIKit recognizers:

- iPhone SE 375 pt / iOS 26.2: 9 тестов, 12 запусков с параметрами,
  0 failures. Покрывает геометрию viewport (включая landscape/tablet), поиск,
  короткое нажатие ровно один раз, удержание без отправки, реальные 44 pt
  touch bounds, обе стороны пузыря, предпросмотр / открытие чата, отступы меню
  и Reduced Motion / Reduce Transparency с принудительным legacy материалом.
  `/private/tmp/alo-20261005-context-native-compact.xcresult`.
- iPhone 17 Pro 402 pt / iOS 26.2: 2 UI-теста, 0 failures — короткое
  нажатие и удержание, поиск / просмотр count / возврат, правый край меню.
  `/private/tmp/alo-20261005-context-native-gestures.xcresult`.
- Скриншоты просмотрены вручную. Сборка Debug simulator успешна. Проверка
  iOS 18 на реальном устройстве, а также frame pacing на нём не выполнялась.

Скриншоты текущего прохода:
[предпросмотр 375 pt](/Users/mikhail/AloiOS/Design/Verification/2026-10-05-context/inbox-preview-375.png),
[расширенные реакции](/Users/mikhail/AloiOS/Design/Verification/2026-10-05-context/reactions-expanded-375.png),
[меню исходящего сообщения 402 pt](/Users/mikhail/AloiOS/Design/Verification/2026-10-05-context/outgoing-menu-402.png),
[просмотр реакции](/Users/mikhail/AloiOS/Design/Verification/2026-10-05-context/reaction-inspection-402.png).
