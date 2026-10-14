# Alo — предложения для остальных разделов

Дата: 13 октября 2026. Изображения созданы встроенным Imagegen. Это отдельные
растровые макеты для согласования, не скриншоты работающего приложения и не
замеры Telegram. Поиск, профиль, список чатов и уведомления ещё не заменены
этими макетами в коде.

## Макеты

| Раздел | Изображение | Основная идея |
| --- | --- | --- |
| Поиск | [search.png](search.png) | Компактный поиск, фильтры и результаты без больших пустых блоков. |
| Профиль | [profile.png](profile.png) | Обложка, увеличенный аватар, компактные счётчики и плоская лента. |
| Список чатов | [chats.png](chats.png) | Поиск, категории, истории и плотные строки переписок. |
| Переписка | [conversation.png](conversation.png) | Тёмные стеклянные панели, компактные цитаты и управление медиа. |
| Уведомления | [notifications.png](notifications.png) | Единый список активности с короткими группами по времени. |
| Пост и комментарии | [post-detail.png](post-detail.png) | Полный исходный пост, крупное медиа и комментарии ниже. |

Общий язык: чёрный фон, синий акцент Alo, серые вторичные подписи; розовый только
у активного лайка. Стекло — у постоянных панелей, не у каждой строки.

Изображение переписки не задаёт размеры кружков и пороги жестов: они проверяются
по исходникам Telegram отдельно. В генерации возможны отклонения пропорций.
В макете комментариев сортировка, вложения и вложенные ответы — предложения;
их наличие на изображении не означает, что эти функции уже реализованы.

## Уже реализованная страница публикации

Компактный предпросмотр с маленькой миниатюрой заменён полноценной страницей:
исходный текст и медиа шириной экрана минус 32 pt, затем комментарии. Медиа
открывается в плеере; возврат кнопкой или системным свайпом сохраняет позицию
ленты. У реального медиа используется существующая сетка 16:9, а не пропорции
сгенерированной картинки. Панель ввода остаётся над клавиатурой.

- [Работающее приложение, 402 pt](native-post-detail-402.png)
- [Работающее приложение, 375 pt](native-post-detail-375.png)

Вдохновение для структуры: полный родительский пост и ответы под ним, а не
карточка-цитата. [Справка X о replies](https://help.x.com/en/using-x/mentions-and-replies)
подтверждает связь с исходной публикацией, но не точные размеры текущего клиента.
Точное пиксельное совпадение с X или VK не заявляется.

## Промпты / брифы генерации

Ниже сохранены содержательные брифы шести генераций, нормализованные для повторного
использования (не побайтовый журнал отправленных промптов).

Общие условия: native iPhone UI mockup, один плоский портретный экран 402×874,
без корпуса телефона, перспективы и коллажа. Чёткий русский текст, SF Pro,
поля 16 pt, область нажатия 44 pt, вторичный текст 12–13 pt. Palette:
`#000000`, `#0E0E10`, `#1D1D1F`, `#28282A`, `#3A3A3D`, `#F5F5F7`,
`#9E9EA6`, `#0A84FF`; subtle dark translucent chrome. Только вымышленные
взрослые люди на фотографиях. В основных разделах единая нижняя навигация:
«Лента», «Поиск», «Чаты», «Уведы», «Профиль»; в публикации и переписке её нет.

1. Search: title «Поиск», search pill «Люди, сообщества и сообщения», compact
   filters «Все», «Люди», «Сообщества», «Сообщения». Recent searches Alexander,
   city community, Maria; two people rows Dasha and Ilya with follow actions;
   two community results. No big statistic tiles, no fake promotional cards.
2. Profile: autumn Moscow river cover about 145 pt, portrait about 86 pt
   overlapping the cover; makkarov, verified badge, @makkarov, short city/photo
   bio. Inline friends/followers/following counters, edit and palette controls,
   common «Посты / Нравятся» oval. Flat photo post with compact engagement row.
3. Chats: «Чаты», edit/compose controls, search, compact categories, five story
   circles. Conversation rows: saved messages, Alexander, Maria voice 0:18,
   city community, college group, Ilya circle 0:12, Dasha. Small timestamps,
   unread badges, no card around each conversation.
4. Conversation: Maria header, «была недавно», subtle dark chat pattern,
   «Сегодня». Incoming hello, outgoing city reply, voice 0:18, compact quoted
   reply and a circular video message. Dark attachment/input/microphone
   controls with a small down/unread control aligned over the microphone.
   Subtle short black edge fades. No excessive gradients or separate media cards.
5. Notifications: «Уведомления», filters all/replies/reactions; Alexander
   comment, Maria like, Dasha friend request with accept/reject, Ilya reply,
   yesterday city post and repost. Short readable rows, small source thumbnails,
   no advertising blocks or oversized empty states.
6. Post detail: «Публикация», full author header and original autumn photo post,
   full-width large landscape media, reply/repost/like/views row (8/3/42/1.2K).
   «Комментарии 8», Alexander asking where it was taken, author reply, Maria
   compliment. Fixed comment composer; no sheet handle or main bottom tabs.

## Проверка и ограничения

Apple Design повлиял на непрерывную навигацию, разделение контента и постоянных
панелей; Animate — на локальный отклик и прерываемые переходы. UI/UX Pro Max
использован для проверки структуры, но найденная им landing-page палитра
отклонена: используются цвета Alo. У `apple-design-dickwu` отсутствуют HIG
reference files, поэтому полный HIG-аудит не заявляется.

Страница публикации: по 22/22 проверки на iPhone 17 Pro и SE 3, iOS Simulator
26.2. Результаты: `/tmp/AloPostDetail-20261013-Pro.xcresult` и
`/tmp/AloPostDetail-20261013-SE.xcresult`. Проверены крупное медиа, открытие
фото/видео, отправка и повторное открытие комментариев на локальной fixture,
возврат со сохранением позиции, large text, Reduce Motion и legacy glass.
Сервер и физический iPhone этим прогоном не проверялись; iOS 18 runtime нет.

Механику кружков и навигации см. в [отдельном сравнении](../TELEGRAM-MECHANICS-2026-10-13.md).

В расширенном прогоне до последней правки слоя миниатюры: 74/74 уникальных теста
на Pro (88 запусков с параметрами), `/tmp/AloCommentsAndChat-20261013-Pro-verified.xcresult`.
Прогон Keychain выполняется с локальной ad-hoc подписью симулятора; прогон без
подписи дал отказ сохранения ключа и не используется как подтверждение работы
очереди. Защита outbox не ослаблена; в ошибку добавлен OSStatus для диагностики.

Последние исправления видимости стрелки и возврата к последнему сообщению:
по 10/10 затронутых unit/UI-сценариев на Pro и SE. См. результаты и найденные
проблемы в отдельном сравнении Telegram выше. Это не повтор всех 74 тестов.
