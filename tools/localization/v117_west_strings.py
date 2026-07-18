# -*- coding: utf-8 -*-
"""Western-language strings introduced by the AI power orchestration work.

This overlay stays separate from the generated catalogs so it can be reviewed
and merged without creating noisy changes in the large localization files.
"""

import re

try:
    from .v117_main_strings import APP as MAIN_APP, CORE as MAIN_CORE
except ImportError:
    from v117_main_strings import APP as MAIN_APP, CORE as MAIN_CORE


LANGUAGES = ("it", "ru", "pt-BR", "tr", "pl", "uk")


APP = {
    "%d active Agent lease(s)": {
        "it": "%d lease di veglia attivi degli agenti",
        "ru": "Активных аренд бодрствования агентов: %d",
        "pt-BR": "%d leases de vigília de agentes ativos",
        "tr": "%d etkin Agent uyanık tutma kiralaması",
        "pl": "%d aktywnych dzierżaw czuwania agentów",
        "uk": "Активних оренд підтримки активності агентів: %d",
    },
    "%d active local automation(s)": {
        "it": "%d automazioni locali attive",
        "ru": "Активных локальных автоматизаций: %d",
        "pt-BR": "%d automações locais ativas",
        "tr": "%d etkin yerel otomasyon",
        "pl": "%d aktywnych lokalnych automatyzacji",
        "uk": "Активних локальних автоматизацій: %d",
    },
    "%d automation file(s) could not be used": {
        "it": "Impossibile usare %d file di automazione",
        "ru": "Файлы автоматизации, которые не удалось использовать: %d",
        "pt-BR": "Não foi possível usar %d arquivos de automação",
        "tr": "%d otomasyon dosyası kullanılamadı",
        "pl": "Nie udało się użyć %d plików automatyzacji",
        "uk": "Файли автоматизації, які не вдалося використати: %d",
    },
    "%d%%": {
        "it": "%d%%",
        "ru": "%d%%",
        "pt-BR": "%d%%",
        "tr": "%d%%",
        "pl": "%d%%",
        "uk": "%d%%",
    },
    "+%d more Agent lease(s)": {
        "it": "+%d altri lease di veglia degli agenti",
        "ru": "+%d других аренд бодрствования агентов",
        "pt-BR": "+%d outros leases de vigília de agentes",
        "tr": "+%d Agent uyanık tutma kiralaması daha",
        "pl": "+%d dodatkowych dzierżaw czuwania agentów",
        "uk": "+%d інших оренд підтримки активності агентів",
    },
    "20 minutes": {
        "it": "20 minuti",
        "ru": "20 минут",
        "pt-BR": "20 minutos",
        "tr": "20 dakika",
        "pl": "20 minut",
        "uk": "20 хвилин",
    },
    "After all unattended work": {
        "it": "Dopo tutto il lavoro non supervisionato",
        "ru": "После всей работы без присмотра",
        "pt-BR": "Depois de todo o trabalho sem supervisão",
        "tr": "Tüm gözetimsiz işlerden sonra",
        "pl": "Po zakończeniu całej pracy bez nadzoru",
        "uk": "Після всієї роботи без нагляду",
    },
    "Agent and unattended log": {
        "it": "Registro degli agenti e del lavoro non supervisionato",
        "ru": "Журнал агентов и работы без присмотра",
        "pt-BR": "Registro de agentes e trabalho sem supervisão",
        "tr": "Agent ve gözetimsiz çalışma günlüğü",
        "pl": "Dziennik agentów i pracy bez nadzoru",
        "uk": "Журнал агентів і роботи без нагляду",
    },
    "Agent lease: %@": {
        "it": "Lease di veglia dell'agente: %@",
        "ru": "Аренда бодрствования агента: %@",
        "pt-BR": "Lease de vigília do agente: %@",
        "tr": "Agent uyanık tutma kiralaması: %@",
        "pl": "Dzierżawa czuwania agenta: %@",
        "uk": "Оренда підтримки активності агента: %@",
    },
    "Agent wake lease expired": {
        "it": "Lease di veglia dell'agente scaduto",
        "ru": "Срок аренды бодрствования агента истёк",
        "pt-BR": "O lease de vigília do agente expirou",
        "tr": "Agent uyanık tutma kiralamasının süresi doldu",
        "pl": "Dzierżawa czuwania agenta wygasła",
        "uk": "Термін оренди підтримки активності агента минув",
    },
    "Agent work owns keep-awake until every lease and scheduled handoff finishes.": {
        "it": "Il lavoro degli agenti mantiene il Mac attivo finché ogni lease e passaggio programmato non termina.",
        "ru": "Работа агентов удерживает Mac активным, пока не завершатся все аренды и запланированные передачи.",
        "pt-BR": "O trabalho dos agentes mantém o Mac acordado até que todos os leases e repasses agendados terminem.",
        "tr": "Agent işi, tüm kiralamalar ve zamanlanmış devirler bitene kadar Mac'i uyanık tutar.",
        "pl": "Praca agentów utrzymuje Maca w czuwaniu, aż zakończą się wszystkie dzierżawy i zaplanowane przekazania.",
        "uk": "Робота агентів підтримує активність Mac, доки не завершаться всі оренди й заплановані передавання.",
    },
    "An Agent stopped renewing its lease. Keepresso released that task's wake request safely.": {
        "it": "Un agente ha smesso di rinnovare il lease. Keepresso ha rilasciato in sicurezza la richiesta di veglia dell'attività.",
        "ru": "Агент перестал продлевать аренду. Keepresso безопасно снял запрос этой задачи на бодрствование.",
        "pt-BR": "Um agente parou de renovar seu lease. O Keepresso liberou com segurança a solicitação de vigília dessa tarefa.",
        "tr": "Bir Agent kiralamasını yenilemeyi bıraktı. Keepresso bu görevin uyanık tutma isteğini güvenle bıraktı.",
        "pl": "Agent przestał odnawiać swoją dzierżawę. Keepresso bezpiecznie zwolniło żądanie czuwania tego zadania.",
        "uk": "Агент перестав поновлювати оренду. Keepresso безпечно зняв запит цього завдання на підтримку активності.",
    },
    "Automation prompt text is discarded during parsing and is never retained, displayed, or logged. Configure the Keepresso Skill or MCP server so each Agent acquires, renews, and releases its own lease.": {
        "it": "Il testo del prompt di automazione viene scartato durante l'analisi e non viene mai conservato, mostrato o registrato. Configura la Skill Keepresso o il server MCP affinché ogni agente acquisisca, rinnovi e rilasci il proprio lease.",
        "ru": "Текст запроса автоматизации отбрасывается при разборе и никогда не сохраняется, не отображается и не записывается в журнал. Настройте Skill Keepresso или сервер MCP, чтобы каждый агент получал, продлевал и освобождал собственную аренду.",
        "pt-BR": "O texto do prompt de automação é descartado durante a análise e nunca é mantido, exibido ou registrado. Configure a Skill do Keepresso ou o servidor MCP para que cada agente adquira, renove e libere seu próprio lease.",
        "tr": "Otomasyon istemi metni ayrıştırma sırasında atılır; hiçbir zaman saklanmaz, gösterilmez veya günlüğe yazılmaz. Her Agent'ın kendi kiralamasını alması, yenilemesi ve bırakması için Keepresso Skill'ini ya da MCP sunucusunu yapılandırın.",
        "pl": "Treść monitu automatyzacji jest odrzucana podczas analizy i nigdy nie jest zachowywana, wyświetlana ani zapisywana w dzienniku. Skonfiguruj Skill Keepresso lub serwer MCP, aby każdy agent uzyskiwał, odnawiał i zwalniał własną dzierżawę.",
        "uk": "Текст запиту автоматизації відкидається під час аналізу й ніколи не зберігається, не відображається та не записується в журнал. Налаштуйте Skill Keepresso або сервер MCP, щоб кожен агент отримував, поновлював і звільняв власну оренду.",
    },
    "Automation discovery completed": {
        "it": "Rilevamento delle automazioni completato",
        "ru": "Обнаружение автоматизаций завершено",
        "pt-BR": "Descoberta de automações concluída",
        "tr": "Otomasyon keşfi tamamlandı",
        "pl": "Wykrywanie automatyzacji zakończone",
        "uk": "Виявлення автоматизацій завершено",
    },
    "Automation discovery failed": {
        "it": "Rilevamento delle automazioni non riuscito",
        "ru": "Не удалось обнаружить автоматизации",
        "pt-BR": "Falha na descoberta de automações",
        "tr": "Otomasyon keşfi başarısız oldu",
        "pl": "Wykrywanie automatyzacji nie powiodło się",
        "uk": "Не вдалося виявити автоматизації",
    },
    "Closed-lid protection needs the administrator helper.": {
        "it": "La protezione a coperchio chiuso richiede l'assistente amministratore.",
        "ru": "Для защиты при закрытой крышке нужен помощник с правами администратора.",
        "pt-BR": "A proteção com a tampa fechada precisa do assistente de administrador.",
        "tr": "Kapak kapalı koruması için yönetici yardımcısı gerekir.",
        "pl": "Ochrona przy zamkniętej pokrywie wymaga pomocnika administratora.",
        "uk": "Для захисту із закритою кришкою потрібен помічник із правами адміністратора.",
    },
    "Codex automation did not claim a wake lease": {
        "it": "L'automazione Codex non ha richiesto un lease di veglia",
        "ru": "Автоматизация Codex не запросила аренду бодрствования",
        "pt-BR": "A automação do Codex não solicitou um lease de vigília",
        "tr": "Codex otomasyonu uyanık tutma kiralaması almadı",
        "pl": "Automatyzacja Codex nie uzyskała dzierżawy czuwania",
        "uk": "Автоматизація Codex не запросила оренду підтримки активності",
    },
    "Codex automation idle": {
        "it": "Automazione Codex inattiva",
        "ru": "Автоматизация Codex бездействует",
        "pt-BR": "Automação do Codex ociosa",
        "tr": "Codex otomasyonu boşta",
        "pl": "Automatyzacja Codex jest bezczynna",
        "uk": "Автоматизація Codex неактивна",
    },
    "Codex automation needs the administrator helper": {
        "it": "L'automazione Codex richiede l'assistente amministratore",
        "ru": "Для автоматизации Codex нужен помощник администратора",
        "pt-BR": "A automação do Codex precisa do assistente de administrador",
        "tr": "Codex otomasyonu için yönetici yardımcısı gerekir",
        "pl": "Automatyzacja Codex wymaga pomocnika administratora",
        "uk": "Для автоматизації Codex потрібен помічник адміністратора",
    },
    "Codex automation preparation": {
        "it": "Preparazione dell'automazione Codex",
        "ru": "Подготовка автоматизации Codex",
        "pt-BR": "Preparação da automação do Codex",
        "tr": "Codex otomasyonu hazırlanıyor",
        "pl": "Przygotowanie automatyzacji Codex",
        "uk": "Підготовка автоматизації Codex",
    },
    "Codex automation readiness failed": {
        "it": "Verifica di preparazione dell'automazione Codex non riuscita",
        "ru": "Проверка готовности автоматизации Codex не пройдена",
        "pt-BR": "Falha na verificação de prontidão da automação do Codex",
        "tr": "Codex otomasyonu hazırlık denetimi başarısız oldu",
        "pl": "Sprawdzanie gotowości automatyzacji Codex nie powiodło się",
        "uk": "Перевірку готовності автоматизації Codex не пройдено",
    },
    "Codex automation wake": {
        "it": "Sveglia per l'automazione Codex",
        "ru": "Пробуждение для автоматизации Codex",
        "pt-BR": "Despertar para automação do Codex",
        "tr": "Codex otomasyonu için uyandırma",
        "pl": "Wybudzenie dla automatyzacji Codex",
        "uk": "Пробудження для автоматизації Codex",
    },
    "Codex automation wake is saved but inactive until the administrator helper is ready.": {
        "it": "La sveglia per l'automazione Codex è salvata, ma resta inattiva finché l'assistente amministratore non è pronto.",
        "ru": "Пробуждение для автоматизации Codex сохранено, но неактивно, пока помощник администратора не готов.",
        "pt-BR": "O despertar para automação do Codex está salvo, mas inativo até o assistente de administrador estar pronto.",
        "tr": "Codex otomasyonu uyandırması kaydedildi ancak yönetici yardımcısı hazır olana kadar etkin değil.",
        "pl": "Wybudzenie dla automatyzacji Codex jest zapisane, ale pozostaje nieaktywne, dopóki pomocnik administratora nie będzie gotowy.",
        "uk": "Пробудження для автоматизації Codex збережено, але воно неактивне, доки помічник адміністратора не буде готовий.",
    },
    "Codex automation was not started": {
        "it": "L'automazione Codex non è stata avviata",
        "ru": "Автоматизация Codex не была запущена",
        "pt-BR": "A automação do Codex não foi iniciada",
        "tr": "Codex otomasyonu başlatılmadı",
        "pl": "Automatyzacja Codex nie została uruchomiona",
        "uk": "Автоматизацію Codex не запущено",
    },
    "Follow local Codex automations": {
        "it": "Segui le automazioni Codex locali",
        "ru": "Отслеживать локальные автоматизации Codex",
        "pt-BR": "Acompanhar automações locais do Codex",
        "tr": "Yerel Codex otomasyonlarını izle",
        "pl": "Śledź lokalne automatyzacje Codex",
        "uk": "Відстежувати локальні автоматизації Codex",
    },
    "Held by %d Agent lease(s)": {
        "it": "Mantenuto attivo da %d lease degli agenti",
        "ru": "Удерживается арендой бодрствования агентов: %d",
        "pt-BR": "Mantido acordado por %d leases de agentes",
        "tr": "%d Agent kiralaması tarafından uyanık tutuluyor",
        "pl": "Utrzymywane przez %d dzierżaw czuwania agentów",
        "uk": "Активність підтримують оренди агентів: %d",
    },
    "Install and approve the helper before relying on unattended wake or closed-lid work.": {
        "it": "Installa e approva l'assistente prima di affidarti alla sveglia non supervisionata o al lavoro con coperchio chiuso.",
        "ru": "Установите и разрешите помощник, прежде чем полагаться на пробуждение без присмотра или работу с закрытой крышкой.",
        "pt-BR": "Instale e aprove o assistente antes de depender do despertar sem supervisão ou do trabalho com a tampa fechada.",
        "tr": "Gözetimsiz uyandırmaya veya kapak kapalı çalışmaya güvenmeden önce yardımcıyı kurup onaylayın.",
        "pl": "Zainstaluj i zatwierdź pomocnika, zanim zaczniesz polegać na wybudzaniu bez nadzoru lub pracy z zamkniętą pokrywą.",
        "uk": "Установіть і схваліть помічник, перш ніж покладатися на пробудження без нагляду чи роботу із закритою кришкою.",
    },
    "Keepresso extracts only scheduling metadata from enabled local Codex automations. It wakes the Mac before the nearest run, waits for power, battery, network, and the Codex app, then holds the Mac until the Agent acquires an explicit lease or the handoff times out.": {
        "it": "Keepresso estrae solo i metadati di pianificazione dalle automazioni Codex locali abilitate. Sveglia il Mac prima dell'esecuzione più vicina, attende che alimentazione, batteria, rete e app Codex siano pronte, quindi mantiene attivo il Mac finché l'agente non acquisisce un lease esplicito o il passaggio non scade.",
        "ru": "Keepresso извлекает только метаданные расписания из включённых локальных автоматизаций Codex. Он пробуждает Mac перед ближайшим запуском, ждёт готовности питания, батареи, сети и приложения Codex, а затем удерживает Mac активным, пока агент не получит явную аренду или не истечёт время передачи.",
        "pt-BR": "O Keepresso extrai apenas os metadados de agendamento das automações locais do Codex ativadas. Ele desperta o Mac antes da execução mais próxima, espera a energia, a bateria, a rede e o app Codex ficarem prontos e mantém o Mac acordado até o agente adquirir um lease explícito ou o repasse expirar.",
        "tr": "Keepresso, etkin yerel Codex otomasyonlarından yalnızca zamanlama meta verilerini çıkarır. En yakın çalıştırmadan önce Mac'i uyandırır; gücün, pilin, ağın ve Codex uygulamasının hazır olmasını bekler; ardından Agent açık bir kiralama alana veya devir süresi dolana kadar Mac'i uyanık tutar.",
        "pl": "Keepresso pobiera tylko metadane harmonogramu z włączonych lokalnych automatyzacji Codex. Wybudza Maca przed najbliższym uruchomieniem, czeka na gotowość zasilania, baterii, sieci i aplikacji Codex, a następnie utrzymuje Maca w czuwaniu, dopóki agent nie uzyska jawnej dzierżawy lub nie upłynie czas przekazania.",
        "uk": "Keepresso видобуває лише метадані розкладу з увімкнених локальних автоматизацій Codex. Він пробуджує Mac перед найближчим запуском, очікує готовності живлення, акумулятора, мережі та застосунку Codex, а потім підтримує активність Mac, доки агент не отримає явну оренду або не мине час передавання.",
    },
    "Keepresso released the expired handoff requests. Any Agent leases still active remain protected.": {
        "it": "Keepresso ha rilasciato le richieste di passaggio scadute. Tutti i lease degli agenti ancora attivi restano protetti.",
        "ru": "Keepresso снял просроченные запросы передачи. Все ещё активные аренды агентов остаются защищёнными.",
        "pt-BR": "O Keepresso liberou as solicitações de repasse expiradas. Os leases de agentes ainda ativos continuam protegidos.",
        "tr": "Keepresso süresi dolan devir isteklerini bıraktı. Hâlâ etkin olan Agent kiralamaları korunmaya devam eder.",
        "pl": "Keepresso zwolniło wygasłe żądania przekazania. Nadal aktywne dzierżawy agentów pozostają chronione.",
        "uk": "Keepresso зняв прострочені запити передавання. Усі ще активні оренди агентів залишаються захищеними.",
    },
    "Lease acquired": {
        "it": "Lease acquisito",
        "ru": "Аренда получена",
        "pt-BR": "Lease adquirido",
        "tr": "Kiralama alındı",
        "pl": "Uzyskano dzierżawę",
        "uk": "Оренду отримано",
    },
    "Lease changed by another process": {
        "it": "Lease modificato da un altro processo",
        "ru": "Аренда изменена другим процессом",
        "pt-BR": "Lease alterado por outro processo",
        "tr": "Kiralama başka bir işlem tarafından değiştirildi",
        "pl": "Dzierżawa zmieniona przez inny proces",
        "uk": "Оренду змінено іншим процесом",
    },
    "Lease heartbeat received": {
        "it": "Segnale di attività del lease ricevuto",
        "ru": "Получен сигнал активности аренды",
        "pt-BR": "Sinal de atividade do lease recebido",
        "tr": "Kiralama yaşam sinyali alındı",
        "pl": "Odebrano sygnał aktywności dzierżawy",
        "uk": "Отримано сигнал активності оренди",
    },
    "Lease released": {
        "it": "Lease rilasciato",
        "ru": "Аренда освобождена",
        "pt-BR": "Lease liberado",
        "tr": "Kiralama bırakıldı",
        "pl": "Dzierżawa zwolniona",
        "uk": "Оренду звільнено",
    },
    "Lease renewed": {
        "it": "Lease rinnovato",
        "ru": "Аренда продлена",
        "pt-BR": "Lease renovado",
        "tr": "Kiralama yenilendi",
        "pl": "Dzierżawa odnowiona",
        "uk": "Оренду поновлено",
    },
    "Lease restored after restart": {
        "it": "Lease ripristinato dopo il riavvio",
        "ru": "Аренда восстановлена после перезапуска",
        "pt-BR": "Lease restaurado após a reinicialização",
        "tr": "Kiralama yeniden başlatmanın ardından geri yüklendi",
        "pl": "Dzierżawa przywrócona po ponownym uruchomieniu",
        "uk": "Оренду відновлено після перезапуску",
    },
    "Lease timed out": {
        "it": "Tempo del lease scaduto",
        "ru": "Время аренды истекло",
        "pt-BR": "Tempo limite do lease esgotado",
        "tr": "Kiralama zaman aşımına uğradı",
        "pl": "Upłynął limit czasu dzierżawy",
        "uk": "Час очікування оренди минув",
    },
    "Lock screen before unattended work": {
        "it": "Blocca lo schermo prima del lavoro non supervisionato",
        "ru": "Блокировать экран перед работой без присмотра",
        "pt-BR": "Bloquear a tela antes do trabalho sem supervisão",
        "tr": "Gözetimsiz işten önce ekranı kilitle",
        "pl": "Zablokuj ekran przed pracą bez nadzoru",
        "uk": "Блокувати екран перед роботою без нагляду",
    },
    "MCP server": {
        "it": "Server MCP",
        "ru": "Сервер MCP",
        "pt-BR": "Servidor MCP",
        "tr": "MCP sunucusu",
        "pl": "Serwer MCP",
        "uk": "Сервер MCP",
    },
    "Minimum battery": {
        "it": "Livello minimo della batteria",
        "ru": "Минимальный заряд батареи",
        "pt-BR": "Bateria mínima",
        "tr": "En düşük pil düzeyi",
        "pl": "Minimalny poziom baterii",
        "uk": "Мінімальний заряд акумулятора",
    },
    "Next run: %@": {
        "it": "Prossima esecuzione: %@",
        "ru": "Следующий запуск: %@",
        "pt-BR": "Próxima execução: %@",
        "tr": "Sonraki çalıştırma: %@",
        "pl": "Następne uruchomienie: %@",
        "uk": "Наступний запуск: %@",
    },
    "Next wake: %@": {
        "it": "Prossima sveglia: %@",
        "ru": "Следующее пробуждение: %@",
        "pt-BR": "Próximo despertar: %@",
        "tr": "Sonraki uyandırma: %@",
        "pl": "Następne wybudzenie: %@",
        "uk": "Наступне пробудження: %@",
    },
    "No Agent or unattended activity yet.": {
        "it": "Ancora nessuna attività degli agenti o non supervisionata.",
        "ru": "Пока нет активности агентов или работы без присмотра.",
        "pt-BR": "Ainda não há atividade de agentes nem trabalho sem supervisão.",
        "tr": "Henüz Agent veya gözetimsiz çalışma etkinliği yok.",
        "pl": "Nie ma jeszcze aktywności agentów ani pracy bez nadzoru.",
        "uk": "Активності агентів або роботи без нагляду ще немає.",
    },
    "No enabled local Codex automation found": {
        "it": "Nessuna automazione Codex locale abilitata trovata",
        "ru": "Включённые локальные автоматизации Codex не найдены",
        "pt-BR": "Nenhuma automação local do Codex ativada foi encontrada",
        "tr": "Etkin yerel Codex otomasyonu bulunamadı",
        "pl": "Nie znaleziono włączonej lokalnej automatyzacji Codex",
        "uk": "Не знайдено ввімкнених локальних автоматизацій Codex",
    },
    "Opening Codex": {
        "it": "Apertura di Codex",
        "ru": "Открытие Codex",
        "pt-BR": "Abrindo o Codex",
        "tr": "Codex açılıyor",
        "pl": "Otwieranie Codex",
        "uk": "Відкриття Codex",
    },
    "Power, network, or the Codex application did not become ready in time.": {
        "it": "L'alimentazione, la rete o l'applicazione Codex non sono diventate pronte in tempo.",
        "ru": "Питание, сеть или приложение Codex не были готовы вовремя.",
        "pt-BR": "A energia, a rede ou o aplicativo Codex não ficaram prontos a tempo.",
        "tr": "Güç, ağ veya Codex uygulaması zamanında hazır olmadı.",
        "pl": "Zasilanie, sieć lub aplikacja Codex nie były gotowe na czas.",
        "uk": "Живлення, мережа або застосунок Codex не були готові вчасно.",
    },
    "Preparation window is open now": {
        "it": "La finestra di preparazione è aperta",
        "ru": "Окно подготовки уже открыто",
        "pt-BR": "A janela de preparação está aberta agora",
        "tr": "Hazırlık aralığı şimdi açık",
        "pl": "Okno przygotowania jest już otwarte",
        "uk": "Вікно підготовки вже відкрите",
    },
    "Readiness timeout": {
        "it": "Tempo limite di preparazione",
        "ru": "Лимит времени готовности",
        "pt-BR": "Tempo limite de prontidão",
        "tr": "Hazırlık zaman aşımı",
        "pl": "Limit czasu gotowości",
        "uk": "Час очікування готовності",
    },
    "Readiness checks passed": {
        "it": "Verifiche di preparazione superate",
        "ru": "Проверки готовности пройдены",
        "pt-BR": "Verificações de prontidão concluídas",
        "tr": "Hazırlık denetimleri geçti",
        "pl": "Sprawdzanie gotowości zakończone pomyślnie",
        "uk": "Перевірки готовності пройдено",
    },
    "Readiness retry scheduled": {
        "it": "Nuovo tentativo di preparazione pianificato",
        "ru": "Повторная проверка готовности запланирована",
        "pt-BR": "Nova tentativa de prontidão agendada",
        "tr": "Hazırlık yeniden denemesi zamanlandı",
        "pl": "Zaplanowano ponowne sprawdzenie gotowości",
        "uk": "Повторну перевірку готовності заплановано",
    },
    "Readiness timed out": {
        "it": "Tempo di preparazione scaduto",
        "ru": "Время проверки готовности истекло",
        "pt-BR": "Tempo de prontidão esgotado",
        "tr": "Hazırlık zaman aşımına uğradı",
        "pl": "Upłynął limit czasu gotowości",
        "uk": "Час перевірки готовності минув",
    },
    "Require external power": {
        "it": "Richiedi alimentazione esterna",
        "ru": "Требовать внешнее питание",
        "pt-BR": "Exigir energia externa",
        "tr": "Harici güç gerektir",
        "pl": "Wymagaj zasilania zewnętrznego",
        "uk": "Вимагати зовнішнє живлення",
    },
    "Require minimum battery": {
        "it": "Richiedi un livello minimo della batteria",
        "ru": "Требовать минимальный заряд батареи",
        "pt-BR": "Exigir nível mínimo de bateria",
        "tr": "En düşük pil düzeyini gerektir",
        "pl": "Wymagaj minimalnego poziomu baterii",
        "uk": "Вимагати мінімальний заряд акумулятора",
    },
    "Require network": {
        "it": "Richiedi la rete",
        "ru": "Требовать сеть",
        "pt-BR": "Exigir rede",
        "tr": "Ağ gerektir",
        "pl": "Wymagaj sieci",
        "uk": "Вимагати мережу",
    },
    "Reveal Keepresso Agent Skill": {
        "it": "Mostra la Skill Agent di Keepresso",
        "ru": "Показать Skill агента Keepresso",
        "pt-BR": "Mostrar a Skill de agente do Keepresso",
        "tr": "Keepresso Agent Skill'ini göster",
        "pl": "Pokaż Skill agenta Keepresso",
        "uk": "Показати Skill агента Keepresso",
    },
    "Scheduled Agent lease active": {
        "it": "Lease programmato dell'agente attivo",
        "ru": "Запланированная аренда агента активна",
        "pt-BR": "Lease agendado do agente ativo",
        "tr": "Zamanlanmış Agent kiralaması etkin",
        "pl": "Zaplanowana dzierżawa agenta jest aktywna",
        "uk": "Запланована оренда агента активна",
    },
    "Scheduled and Agent-driven jobs use a separate secure policy. By default Keepresso locks the login session, turns off the display while preserving the system assertion, and sleeps the Mac after the final job finishes.": {
        "it": "Le attività programmate e guidate dagli agenti usano una politica di sicurezza separata. Per impostazione predefinita, Keepresso blocca la sessione di accesso, spegne il display mantenendo attiva l'asserzione di sistema e mette in stop il Mac al termine dell'ultima attività.",
        "ru": "Запланированные и управляемые агентами задачи используют отдельную политику безопасности. По умолчанию Keepresso блокирует сеанс входа, выключает дисплей, сохраняя системный запрос на бодрствование, и усыпляет Mac после завершения последней задачи.",
        "pt-BR": "As tarefas agendadas e controladas por agentes usam uma política de segurança separada. Por padrão, o Keepresso bloqueia a sessão de login, apaga a tela mantendo a asserção do sistema e suspende o Mac após a última tarefa terminar.",
        "tr": "Zamanlanmış ve Agent tarafından yürütülen işler ayrı bir güvenlik politikası kullanır. Keepresso varsayılan olarak oturum açma oturumunu kilitler, sistem güç bildirimini korurken ekranı kapatır ve son iş tamamlandıktan sonra Mac'i uyutur.",
        "pl": "Zaplanowane zadania i zadania sterowane przez agentów korzystają z osobnych bezpiecznych zasad. Domyślnie Keepresso blokuje sesję logowania, wyłącza wyświetlacz z zachowaniem asercji systemowej i usypia Maca po zakończeniu ostatniego zadania.",
        "uk": "Заплановані й керовані агентами завдання використовують окрему політику безпеки. Типово Keepresso блокує сеанс входу, вимикає дисплей, зберігаючи системний запит на активність, і присипляє Mac після завершення останнього завдання.",
    },
    "Some Codex automations did not claim a wake lease": {
        "it": "Alcune automazioni Codex non hanno richiesto un lease di veglia",
        "ru": "Некоторые автоматизации Codex не запросили аренду бодрствования",
        "pt-BR": "Algumas automações do Codex não solicitaram um lease de vigília",
        "tr": "Bazı Codex otomasyonları uyanık tutma kiralaması almadı",
        "pl": "Niektóre automatyzacje Codex nie uzyskały dzierżawy czuwania",
        "uk": "Деякі автоматизації Codex не запросили оренду підтримки активності",
    },
    "Structured events only, with no automation prompts or command arguments. Saved at %@": {
        "it": "Solo eventi strutturati, senza prompt di automazione o argomenti dei comandi. Salvato in %@",
        "ru": "Только структурированные события, без запросов автоматизации и аргументов команд. Сохранено в %@",
        "pt-BR": "Apenas eventos estruturados, sem prompts de automação nem argumentos de comandos. Salvo em %@",
        "tr": "Yalnızca yapılandırılmış olaylar, otomasyon istemleri veya komut bağımsız değişkenleri yok. Şuraya kaydedildi: %@",
        "pl": "Tylko zdarzenia strukturalne, bez monitów automatyzacji i argumentów poleceń. Zapisano w %@",
        "uk": "Лише структуровані події, без запитів автоматизації та аргументів команд. Збережено в %@",
    },
    "System is eligible to sleep": {
        "it": "Il sistema può entrare in stop",
        "ru": "Система может перейти в сон",
        "pt-BR": "O sistema pode entrar em repouso",
        "tr": "Sistem uykuya geçebilir",
        "pl": "System może przejść w tryb uśpienia",
        "uk": "Система може перейти в режим сну",
    },
    "The Agent lease registry could not be opened.": {
        "it": "Impossibile aprire il registro dei lease degli agenti.",
        "ru": "Не удалось открыть реестр аренд агентов.",
        "pt-BR": "Não foi possível abrir o registro de leases de agentes.",
        "tr": "Agent kiralama kayıt defteri açılamadı.",
        "pl": "Nie udało się otworzyć rejestru dzierżaw agentów.",
        "uk": "Не вдалося відкрити реєстр оренд агентів.",
    },
    "The Agent lease registry could not be read.": {
        "it": "Impossibile leggere il registro dei lease degli agenti.",
        "ru": "Не удалось прочитать реестр аренд агентов.",
        "pt-BR": "Não foi possível ler o registro de leases de agentes.",
        "tr": "Agent kiralama kayıt defteri okunamadı.",
        "pl": "Nie udało się odczytać rejestru dzierżaw agentów.",
        "uk": "Не вдалося прочитати реєстр оренд агентів.",
    },
    "The handoff window expired, so Keepresso restored normal sleep safely.": {
        "it": "La finestra di passaggio è scaduta, quindi Keepresso ha ripristinato in sicurezza lo stop normale.",
        "ru": "Окно передачи истекло, поэтому Keepresso безопасно восстановил обычный режим сна.",
        "pt-BR": "A janela de repasse expirou, então o Keepresso restaurou com segurança o repouso normal.",
        "tr": "Devir aralığının süresi doldu, bu nedenle Keepresso normal uykuyu güvenle geri yükledi.",
        "pl": "Okno przekazania wygasło, więc Keepresso bezpiecznie przywróciło normalny tryb uśpienia.",
        "uk": "Вікно передавання минуло, тому Keepresso безпечно відновив звичайний режим сну.",
    },
    "These defaults do not change interactive keep-awake sessions.": {
        "it": "Queste impostazioni predefinite non modificano le sessioni di veglia interattive.",
        "ru": "Эти параметры по умолчанию не меняют интерактивные сеансы поддержания активности.",
        "pt-BR": "Esses padrões não alteram as sessões interativas de vigília.",
        "tr": "Bu varsayılanlar etkileşimli uyanık tutma oturumlarını değiştirmez.",
        "pl": "Te ustawienia domyślne nie zmieniają interaktywnych sesji czuwania.",
        "uk": "Ці типові параметри не змінюють інтерактивні сеанси підтримки активності.",
    },
    "Turn Off Codex Automation Wake": {
        "it": "Disattiva la sveglia per l'automazione Codex",
        "ru": "Выключить пробуждение для автоматизации Codex",
        "pt-BR": "Desativar o despertar para automação do Codex",
        "tr": "Codex otomasyonu uyandırmasını kapat",
        "pl": "Wyłącz wybudzanie dla automatyzacji Codex",
        "uk": "Вимкнути пробудження для автоматизації Codex",
    },
    "Turn display off before unattended work": {
        "it": "Spegni il display prima del lavoro non supervisionato",
        "ru": "Выключать дисплей перед работой без присмотра",
        "pt-BR": "Apagar a tela antes do trabalho sem supervisão",
        "tr": "Gözetimsiz işten önce ekranı kapat",
        "pl": "Wyłącz wyświetlacz przed pracą bez nadzoru",
        "uk": "Вимикати дисплей перед роботою без нагляду",
    },
    "Unattended Agent work": {
        "it": "Lavoro degli agenti non supervisionato",
        "ru": "Работа агентов без присмотра",
        "pt-BR": "Trabalho de agentes sem supervisão",
        "tr": "Gözetimsiz Agent işi",
        "pl": "Praca agentów bez nadzoru",
        "uk": "Робота агентів без нагляду",
    },
    "Unattended event": {
        "it": "Evento non supervisionato",
        "ru": "Событие без присмотра",
        "pt-BR": "Evento sem supervisão",
        "tr": "Gözetimsiz olay",
        "pl": "Zdarzenie bez nadzoru",
        "uk": "Подія без нагляду",
    },
    "Unattended orchestration cancelled": {
        "it": "Orchestrazione non supervisionata annullata",
        "ru": "Оркестрация без присмотра отменена",
        "pt-BR": "Orquestração sem supervisão cancelada",
        "tr": "Gözetimsiz orkestrasyon iptal edildi",
        "pl": "Anulowano orkiestrację bez nadzoru",
        "uk": "Оркестрацію без нагляду скасовано",
    },
    "Unattended task cancelled": {
        "it": "Attività non supervisionata annullata",
        "ru": "Задача без присмотра отменена",
        "pt-BR": "Tarefa sem supervisão cancelada",
        "tr": "Gözetimsiz görev iptal edildi",
        "pl": "Anulowano zadanie bez nadzoru",
        "uk": "Завдання без нагляду скасовано",
    },
    "Unattended task failed": {
        "it": "Attività non supervisionata non riuscita",
        "ru": "Задача без присмотра завершилась с ошибкой",
        "pt-BR": "Falha na tarefa sem supervisão",
        "tr": "Gözetimsiz görev başarısız oldu",
        "pl": "Zadanie bez nadzoru nie powiodło się",
        "uk": "Завдання без нагляду завершилося помилкою",
    },
    "Unattended task started": {
        "it": "Attività non supervisionata avviata",
        "ru": "Задача без присмотра запущена",
        "pt-BR": "Tarefa sem supervisão iniciada",
        "tr": "Gözetimsiz görev başladı",
        "pl": "Uruchomiono zadanie bez nadzoru",
        "uk": "Завдання без нагляду запущено",
    },
    "Unattended task succeeded": {
        "it": "Attività non supervisionata completata",
        "ru": "Задача без присмотра успешно завершена",
        "pt-BR": "Tarefa sem supervisão concluída",
        "tr": "Gözetimsiz görev başarıyla tamamlandı",
        "pl": "Zadanie bez nadzoru zakończone pomyślnie",
        "uk": "Завдання без нагляду успішно завершено",
    },
    "Unattended task timed out": {
        "it": "Tempo dell'attività non supervisionata scaduto",
        "ru": "Время задачи без присмотра истекло",
        "pt-BR": "Tempo limite da tarefa sem supervisão esgotado",
        "tr": "Gözetimsiz görev zaman aşımına uğradı",
        "pl": "Upłynął limit czasu zadania bez nadzoru",
        "uk": "Час завдання без нагляду минув",
    },
    "Unattended work: %@": {
        "it": "Lavoro non supervisionato: %@",
        "ru": "Работа без присмотра: %@",
        "pt-BR": "Trabalho sem supervisão: %@",
        "tr": "Gözetimsiz iş: %@",
        "pl": "Praca bez nadzoru: %@",
        "uk": "Робота без нагляду: %@",
    },
    "Wait for Agent lease": {
        "it": "Attendi il lease dell'agente",
        "ru": "Ждать аренду агента",
        "pt-BR": "Aguardar o lease do agente",
        "tr": "Agent kiralamasını bekle",
        "pl": "Czekaj na dzierżawę agenta",
        "uk": "Очікувати оренду агента",
    },
    "Waiting for power, network, and Codex": {
        "it": "In attesa di alimentazione, rete e Codex",
        "ru": "Ожидание питания, сети и Codex",
        "pt-BR": "Aguardando energia, rede e Codex",
        "tr": "Güç, ağ ve Codex bekleniyor",
        "pl": "Oczekiwanie na zasilanie, sieć i Codex",
        "uk": "Очікування живлення, мережі та Codex",
    },
    "Waiting for the scheduled Agent lease": {
        "it": "In attesa del lease programmato dell'agente",
        "ru": "Ожидание запланированной аренды агента",
        "pt-BR": "Aguardando o lease agendado do agente",
        "tr": "Zamanlanmış Agent kiralaması bekleniyor",
        "pl": "Oczekiwanie na zaplanowaną dzierżawę agenta",
        "uk": "Очікування запланованої оренди агента",
    },
    "Wake planned": {
        "it": "Sveglia pianificata",
        "ru": "Пробуждение запланировано",
        "pt-BR": "Despertar planejado",
        "tr": "Uyandırma planlandı",
        "pl": "Wybudzenie zaplanowane",
        "uk": "Пробудження заплановано",
    },
    "Wake preparation started": {
        "it": "Preparazione della sveglia avviata",
        "ru": "Подготовка к пробуждению началась",
        "pt-BR": "Preparação do despertar iniciada",
        "tr": "Uyandırma hazırlığı başladı",
        "pl": "Rozpoczęto przygotowanie do wybudzenia",
        "uk": "Підготовку до пробудження розпочато",
    },
    "Wake before run": {
        "it": "Sveglia prima dell'esecuzione",
        "ru": "Пробуждать перед запуском",
        "pt-BR": "Despertar antes da execução",
        "tr": "Çalıştırmadan önce uyandır",
        "pl": "Wybudź przed uruchomieniem",
        "uk": "Пробуджувати перед запуском",
    },
}


CORE = {
    "All Agent and scheduled work finished": {
        "it": "Tutto il lavoro degli agenti e programmato è terminato",
        "ru": "Вся работа агентов и запланированная работа завершена",
        "pt-BR": "Todo o trabalho de agentes e agendado foi concluído",
        "tr": "Tüm Agent işleri ve zamanlanmış işler tamamlandı",
        "pl": "Cała praca agentów i zaplanowana praca została zakończona",
        "uk": "Усю роботу агентів і заплановану роботу завершено",
    },
    "All unattended work finished": {
        "it": "Tutto il lavoro non supervisionato è terminato",
        "ru": "Вся работа без присмотра завершена",
        "pt-BR": "Todo o trabalho sem supervisão foi concluído",
        "tr": "Tüm gözetimsiz işler tamamlandı",
        "pl": "Cała praca bez nadzoru została zakończona",
        "uk": "Усю роботу без нагляду завершено",
    },
}


_FORMAT = re.compile(r"%(?:\d+\$)?(?:0\d)?[@d]|%%")
_FORBIDDEN_DASHES = ("\N{EM DASH}", "\N{EN DASH}")


def _format_specifiers(value: str) -> list[str]:
    """Return normalized printf-style placeholders for comparison."""
    return sorted(re.sub(r"^%\d+\$", "%", match) for match in _FORMAT.findall(value))


def validate() -> None:
    """Validate source keys, language coverage, placeholders, and prose style."""
    failures = []
    required_languages = set(LANGUAGES)
    catalogs = (
        ("APP", APP, MAIN_APP),
        ("CORE", CORE, MAIN_CORE),
    )
    for catalog_name, catalog, main_catalog in catalogs:
        actual_keys = set(catalog)
        expected_keys = set(main_catalog)
        if actual_keys != expected_keys:
            missing = sorted(expected_keys - actual_keys)
            extra = sorted(actual_keys - expected_keys)
            failures.append(
                f"{catalog_name}: source keys differ; missing={missing!r}, extra={extra!r}"
            )
        for key, translations in catalog.items():
            actual_languages = set(translations)
            if actual_languages != required_languages:
                failures.append(
                    f"{catalog_name} {key!r}: languages {sorted(actual_languages)!r}, "
                    f"expected {sorted(required_languages)!r}"
                )
            if any(dash in key for dash in _FORBIDDEN_DASHES):
                failures.append(f"{catalog_name} {key!r}: forbidden dash in source key")
            expected_formats = _format_specifiers(key)
            for language, translation in translations.items():
                if not translation.strip():
                    failures.append(f"{catalog_name} {key!r} {language}: empty translation")
                if _format_specifiers(translation) != expected_formats:
                    failures.append(
                        f"{catalog_name} {key!r} {language}: format specifiers differ"
                    )
                if any(dash in translation for dash in _FORBIDDEN_DASHES):
                    failures.append(
                        f"{catalog_name} {key!r} {language}: forbidden dash in translation"
                    )
    if failures:
        raise SystemExit("\n".join(failures))


if __name__ == "__main__":
    validate()
    print(f"v1.17 western strings: OK (APP {len(APP)}, CORE {len(CORE)})")
